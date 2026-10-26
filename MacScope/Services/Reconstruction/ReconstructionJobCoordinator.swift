import CryptoKit
import Darwin
import Foundation
import os

enum ReconstructionJobPauseReason: String, Codable, Hashable, Sendable {
    case pausedByUser
    case modelUnavailable
    /// Terminal failure, not a pause: see ReconstructionJobCoordinatorFailure.modelChanged.
    case modelChanged
    case inferenceBusy
    case frontierMismatch
    case evidenceStalled
    case cancelled
    case failed

    /// The job summary's terminal reason for `.modelChanged`.
    static let modelChangedDiagnostic = "Model changed: this job's recorded model replies cannot be replayed under a different model. Start a new job to use the current model."

    var durablePauseCause: ReconstructionJobPauseCause? {
        switch self {
        case .pausedByUser: .pausedByUser
        case .modelUnavailable: .modelUnavailable
        case .inferenceBusy: .inferenceBusy
        case .frontierMismatch: .frontierMismatch
        case .evidenceStalled: .evidenceStalled
        case .cancelled, .failed, .modelChanged: nil
        }
    }

    var controlDisposition: ReconstructionJobCoordinatorDisposition {
        switch self {
        case .pausedByUser, .modelUnavailable, .inferenceBusy,
             .frontierMismatch, .evidenceStalled:
            .paused(self)
        case .cancelled:
            .cancelled
        case .failed, .modelChanged:
            .failed
        }
    }
}

struct ReconstructionInferenceBusyBackoffPolicy: Hashable, Sendable {
    static let standard = Self(
        initialDelayNanoseconds: 250_000_000,
        maximumDelayNanoseconds: 4_000_000_000,
        maximumAttempts: 6,
        maximumElapsedNanoseconds: 15_000_000_000
    )

    let initialDelayNanoseconds: UInt64
    let maximumDelayNanoseconds: UInt64
    let maximumAttempts: Int
    let maximumElapsedNanoseconds: UInt64

    init(
        initialDelayNanoseconds: UInt64,
        maximumDelayNanoseconds: UInt64,
        maximumAttempts: Int,
        maximumElapsedNanoseconds: UInt64
    ) {
        precondition(initialDelayNanoseconds > 0)
        precondition(maximumDelayNanoseconds >= initialDelayNanoseconds)
        precondition(maximumAttempts >= 0)
        precondition(maximumElapsedNanoseconds > 0)
        self.initialDelayNanoseconds = initialDelayNanoseconds
        self.maximumDelayNanoseconds = maximumDelayNanoseconds
        self.maximumAttempts = maximumAttempts
        self.maximumElapsedNanoseconds = maximumElapsedNanoseconds
    }

    func nextDelay(
        completedAttempts: Int,
        elapsedNanoseconds: UInt64
    ) -> UInt64? {
        guard completedAttempts < maximumAttempts,
              elapsedNanoseconds < maximumElapsedNanoseconds else { return nil }
        var delay = initialDelayNanoseconds
        for _ in 0..<completedAttempts {
            if delay >= maximumDelayNanoseconds { break }
            let (doubled, overflow) = delay.multipliedReportingOverflow(by: 2)
            delay = overflow ? maximumDelayNanoseconds
                : min(doubled, maximumDelayNanoseconds)
        }
        let remaining = maximumElapsedNanoseconds - elapsedNanoseconds
        guard delay <= remaining else { return nil }
        return delay
    }
}

enum ReconstructionJobCoordinatorDisposition: Hashable, Sendable {
    case `continue`
    /// An explicit legal forward hop; ordinary continue never changes durable phase.
    case advancePhase(ReconstructionJobState)
    case completed
    case paused(ReconstructionJobPauseReason)
    case cancelled
    case failed
}

enum ReconstructionJobCoordinatorFailure: Error, Equatable, Sendable {
    case modelUnavailable
    /// Terminal: a recorded reply for this exact request exists under a different selected
    /// model. The job cannot replay it under the current model, so it is never retried.
    case modelChanged
    case inferenceBusy
    case malformedOutput
    case retryableProviderFailure(String)
    case invalidCommitPlan
    case checkpointConflict
    case jobNotFound
}

enum ReconstructionTaskBudgetPause {
    static let diagnostic = "Task budget reached; no successor model request was scheduled."
}

struct ReconstructionJobOrchestrationSnapshot: Hashable, Sendable {
    let jobID: UUID
    let jobCreationOrder: UInt64
    let checkpointID: UUID
    let checkpointRevision: UInt64
    let checkpointCorpusManifestSHA256: String
    let checkpointEvidenceFrontierSHA256: String
    let currentCorpusManifestSHA256: String
    let evidenceFrontierSHA256: String
    let currentDurableJobState: ReconstructionJobState
    let pauseContext: ReconstructionJobPauseContext?
    let maximumRoundsWithoutEvidence: Int
    let tasks: [ReconstructionTaskRecord]
    let terminalReceiptStatesByTaskID: [UUID: ReconstructionTaskState]
    let terminalReceiptCheckpointRevisionsByTaskID: [UUID: UInt64]
    /// Derived exclusively from committed regular-model and selected tool receipts. It is not a
    /// transient loop counter and therefore survives process death, window eviction, and reopen.
    let consecutiveModelRoundsWithoutEvidence: Int

    init(
        jobID: UUID,
        jobCreationOrder: UInt64,
        checkpointID: UUID,
        checkpointRevision: UInt64,
        checkpointCorpusManifestSHA256: String,
        checkpointEvidenceFrontierSHA256: String,
        currentCorpusManifestSHA256: String,
        evidenceFrontierSHA256: String,
        currentDurableJobState: ReconstructionJobState,
        pauseContext: ReconstructionJobPauseContext?,
        maximumRoundsWithoutEvidence: Int,
        tasks: [ReconstructionTaskRecord],
        terminalReceiptStatesByTaskID: [UUID: ReconstructionTaskState],
        consecutiveModelRoundsWithoutEvidence: Int = 0,
        terminalReceiptCheckpointRevisionsByTaskID: [UUID: UInt64]? = nil
    ) {
        self.jobID = jobID
        self.jobCreationOrder = jobCreationOrder
        self.checkpointID = checkpointID
        self.checkpointRevision = checkpointRevision
        self.checkpointCorpusManifestSHA256 = checkpointCorpusManifestSHA256
        self.checkpointEvidenceFrontierSHA256 = checkpointEvidenceFrontierSHA256
        self.currentCorpusManifestSHA256 = currentCorpusManifestSHA256
        self.evidenceFrontierSHA256 = evidenceFrontierSHA256
        self.currentDurableJobState = currentDurableJobState
        self.pauseContext = pauseContext
        self.maximumRoundsWithoutEvidence = maximumRoundsWithoutEvidence
        self.tasks = tasks
        self.terminalReceiptStatesByTaskID = terminalReceiptStatesByTaskID
        self.terminalReceiptCheckpointRevisionsByTaskID = terminalReceiptCheckpointRevisionsByTaskID
            ?? terminalReceiptStatesByTaskID.mapValues { _ in checkpointRevision }
        self.consecutiveModelRoundsWithoutEvidence = consecutiveModelRoundsWithoutEvidence
    }

    var currentDurableActiveState: ReconstructionJobState? {
        if ReconstructionJobState.activeStates.contains(currentDurableJobState) {
            return currentDurableJobState
        }
        if currentDurableJobState == .paused {
            return pauseContext?.resumeTarget
        }
        return nil
    }

    func advancing(
        to revision: UInt64,
        disposition: ReconstructionJobCoordinatorDisposition
    ) throws -> Self {
        let successorState: ReconstructionJobState
        let successorPauseContext: ReconstructionJobPauseContext?
        switch disposition {
        case .advancePhase(let state):
            guard currentDurableJobState != .paused,
                  ReconstructionJobState.activeStates.contains(state),
                  state != currentDurableJobState else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            successorState = state
            successorPauseContext = nil
        case .continue:
            guard let activeState = currentDurableActiveState else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            successorState = activeState
            successorPauseContext = nil
        case .completed:
            successorState = .completed
            successorPauseContext = nil
        case .paused(let reason):
            guard let cause = reason.durablePauseCause,
                  let activeState = currentDurableActiveState else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            successorState = .paused
            successorPauseContext = try ReconstructionJobPauseContext(
                cause: cause,
                resumeTarget: activeState
            )
        case .cancelled:
            successorState = .cancelled
            successorPauseContext = nil
        case .failed:
            successorState = .failed
            successorPauseContext = nil
        }
        if currentDurableJobState != successorState
            || !ReconstructionJobState.activeStates.contains(successorState) {
            let resumeTarget: ReconstructionJobState? = if currentDurableJobState == .paused {
                successorState == .cancelled || successorState == .failed
                    ? nil
                    : pauseContext?.resumeTarget
            } else if successorState == .paused {
                successorPauseContext?.resumeTarget
            } else {
                nil
            }
            do {
                try ReconstructionJobStateMachine.transition(
                    from: currentDurableJobState,
                    to: successorState,
                    resumeTarget: resumeTarget
                )
            } catch {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
        }
        return .init(
            jobID: jobID,
            jobCreationOrder: jobCreationOrder,
            checkpointID: checkpointID,
            checkpointRevision: revision,
            checkpointCorpusManifestSHA256: currentCorpusManifestSHA256,
            checkpointEvidenceFrontierSHA256: evidenceFrontierSHA256,
            currentCorpusManifestSHA256: currentCorpusManifestSHA256,
            evidenceFrontierSHA256: evidenceFrontierSHA256,
            currentDurableJobState: successorState,
            pauseContext: successorPauseContext,
            maximumRoundsWithoutEvidence: maximumRoundsWithoutEvidence,
            tasks: tasks,
            terminalReceiptStatesByTaskID: terminalReceiptStatesByTaskID,
            consecutiveModelRoundsWithoutEvidence: consecutiveModelRoundsWithoutEvidence,
            terminalReceiptCheckpointRevisionsByTaskID: terminalReceiptCheckpointRevisionsByTaskID
        )
    }

    func withCurrentAuthority(
        corpusManifestSHA256: String,
        evidenceFrontierSHA256: String
    ) -> Self {
        .init(
            jobID: jobID,
            jobCreationOrder: jobCreationOrder,
            checkpointID: checkpointID,
            checkpointRevision: checkpointRevision,
            checkpointCorpusManifestSHA256: checkpointCorpusManifestSHA256,
            checkpointEvidenceFrontierSHA256: checkpointEvidenceFrontierSHA256,
            currentCorpusManifestSHA256: corpusManifestSHA256,
            evidenceFrontierSHA256: evidenceFrontierSHA256,
            currentDurableJobState: currentDurableJobState,
            pauseContext: pauseContext,
            maximumRoundsWithoutEvidence: maximumRoundsWithoutEvidence,
            tasks: tasks,
            terminalReceiptStatesByTaskID: terminalReceiptStatesByTaskID,
            consecutiveModelRoundsWithoutEvidence: consecutiveModelRoundsWithoutEvidence,
            terminalReceiptCheckpointRevisionsByTaskID: terminalReceiptCheckpointRevisionsByTaskID
        )
    }
}

struct ReconstructionJobCommitPlan: Sendable {
    let successorRevision: UInt64
    let acceptedEvidenceCount: Int
    let disposition: ReconstructionJobCoordinatorDisposition
    let mutation: ReconstructionCheckpointMutation?
    /// Round-local historical diagnostics only; excluded from the durable mutation and receipts.
    let observationDiagnostics: [ReconstructionProductionObservationDiagnostic]

    init(successorRevision: UInt64, acceptedEvidenceCount: Int,
         disposition: ReconstructionJobCoordinatorDisposition, mutation: ReconstructionCheckpointMutation?,
         observationDiagnostics: [ReconstructionProductionObservationDiagnostic] = []) {
        self.successorRevision = successorRevision; self.acceptedEvidenceCount = acceptedEvidenceCount
        self.disposition = disposition; self.mutation = mutation
        self.observationDiagnostics = observationDiagnostics
    }
}

struct ReconstructionJobCommitReceipt: Sendable {
    let jobID: UUID
    let checkpointRevision: UInt64
    let evidenceFrontierSHA256: String
    let disposition: ReconstructionJobCoordinatorDisposition
    let committedCheckpoint: ReconstructionCommittedCheckpoint?

    init(
        jobID: UUID,
        checkpointRevision: UInt64,
        evidenceFrontierSHA256: String,
        disposition: ReconstructionJobCoordinatorDisposition,
        committedCheckpoint: ReconstructionCommittedCheckpoint? = nil
    ) {
        self.jobID = jobID
        self.checkpointRevision = checkpointRevision
        self.evidenceFrontierSHA256 = evidenceFrontierSHA256
        self.disposition = disposition
        self.committedCheckpoint = committedCheckpoint
    }
}

protocol ReconstructionJobOrchestrationPersisting: Sendable {
    func eligibleJobIDs() async throws -> [UUID]
    func load(jobID: UUID) async throws -> ReconstructionJobOrchestrationSnapshot
    func commit(
        _ plan: ReconstructionJobCommitPlan,
        for snapshot: ReconstructionJobOrchestrationSnapshot
    ) async throws -> ReconstructionJobCommitReceipt
}

extension ReconstructionJobOrchestrationPersisting {
    func eligibleJobIDs() async throws -> [UUID] { [] }
}

protocol ReconstructionJobRoundPlanning: Sendable {
    func planRound(
        from snapshot: ReconstructionJobOrchestrationSnapshot
    ) async throws -> ReconstructionJobCommitPlan
    func planRecovery(
        from snapshot: ReconstructionJobOrchestrationSnapshot,
        transitions: [ReconstructionTaskTransition]
    ) async throws -> ReconstructionJobCommitPlan
    func planControl(
        from snapshot: ReconstructionJobOrchestrationSnapshot,
        reason: ReconstructionJobPauseReason
    ) async throws -> ReconstructionJobCommitPlan
    func cancel(jobID: UUID) async
}

protocol ReconstructionJobStatusPublishing: Sendable {
    func publish(_ receipt: ReconstructionJobCommitReceipt) async
}

@MainActor
protocol ReconstructionReadyInferenceCoordinating: Sendable {
    func proposeSourceRevision(request: ReconstructionSourceRevisionRequest)
        async -> ReconstructionReadySourceRevisionExecutionResult
    func run(
        request: ReconstructionInferenceRoundRequest
    ) async -> ReconstructionReadyInferenceExecutionResult
    func synthesize(
        request: ReconstructionFinalSynthesisRequest
    ) async -> ReconstructionReadyFinalSynthesisExecutionResult
    func run(request: ReconstructionInferenceRoundRequest,
        objective: ReconstructionRequestObjective?) async -> ReconstructionReadyInferenceExecutionResult
    func synthesize(request: ReconstructionFinalSynthesisRequest,
        objective: ReconstructionRequestObjective?) async -> ReconstructionReadyFinalSynthesisExecutionResult
}

extension ReconstructionReadyInferenceCoordinating {
    func proposeSourceRevision(request: ReconstructionSourceRevisionRequest)
        async -> ReconstructionReadySourceRevisionExecutionResult { .invalidRequest }
    func run(request: ReconstructionInferenceRoundRequest,
        objective: ReconstructionRequestObjective?) async -> ReconstructionReadyInferenceExecutionResult {
        guard objective == nil else { return .invalidRequest }
        return await run(request: request)
    }
    func synthesize(request: ReconstructionFinalSynthesisRequest,
        objective: ReconstructionRequestObjective?) async -> ReconstructionReadyFinalSynthesisExecutionResult {
        guard objective == nil else { return .invalidRequest }
        return await synthesize(request: request)
    }
}

struct ReconstructionPreparedModelRound: Sendable {
    let roundID: UUID
    let evidenceCut: ReconstructionEvidenceCut
    let retrievalQuery: ReconstructionRetrievalQuery
    let allowedGapSubjects: [String]
    let allowedGapCategories: [String]
    let authority: ReconstructionToolAuthorityCut
    let requests: [ReconstructionToolRequest]
    let projectorInput: ReconstructionToolProjectorInput
    let sourceRevisionRequest: ReconstructionSourceRevisionRequest?
    /// Explicit app-owned original preparation, qualified against this committed cut.
    let sourceOracleFunction: ReconstructionFunctionCoordinate?
    let sourceOracleRequested: Bool
    let finalSynthesisRequest: ReconstructionFinalSynthesisRequest?
    /// Nil is retained only for explicit legacy R1 fixtures. Production captures this from
    /// the same durable basis as the context, never from a later UI or database read.
    let objective: ReconstructionRequestObjective?
    /// Explicit in-memory continuation disposition of `retrievalQuery`, derived from the committed
    /// selected read receipt. Restarts and end of coverage are stated, never inferred.
    let readContinuation: ReconstructionEvidenceReadContinuation
    /// Bounded native semantics admitted transiently at this exact cut. In memory only: never
    /// persisted, never evidence, and rebuilt (or omitted) for every later round.
    let transientAnalysis: ReconstructionTransientAnalysis?

    init(
        roundID: UUID,
        evidenceCut: ReconstructionEvidenceCut,
        retrievalQuery: ReconstructionRetrievalQuery,
        allowedGapSubjects: [String],
        allowedGapCategories: [String],
        authority: ReconstructionToolAuthorityCut,
        requests: [ReconstructionToolRequest],
        projectorInput: ReconstructionToolProjectorInput,
        sourceRevisionRequest: ReconstructionSourceRevisionRequest? = nil,
        sourceOracleFunction: ReconstructionFunctionCoordinate? = nil,
        sourceOracleRequested: Bool = false,
        finalSynthesisRequest: ReconstructionFinalSynthesisRequest? = nil,
        objective: ReconstructionRequestObjective? = nil,
        readContinuation: ReconstructionEvidenceReadContinuation = .initial,
        transientAnalysis: ReconstructionTransientAnalysis? = nil
    ) {
        self.roundID = roundID
        self.evidenceCut = evidenceCut
        self.retrievalQuery = retrievalQuery
        self.allowedGapSubjects = allowedGapSubjects
        self.allowedGapCategories = allowedGapCategories
        self.authority = authority
        self.requests = requests
        self.projectorInput = projectorInput
        self.sourceRevisionRequest = sourceRevisionRequest
        self.sourceOracleFunction = sourceOracleFunction
        self.sourceOracleRequested = sourceOracleRequested
        self.finalSynthesisRequest = finalSynthesisRequest
        self.objective = objective
        self.readContinuation = readContinuation
        self.transientAnalysis = transientAnalysis
    }
}

/// A production round either advances deterministic work that has already completed or admits
/// one model request. Keeping these branches distinct prevents fresh analysis/native results from
/// crossing a model boundary before their task transitions and discovered coordinates commit.
enum ReconstructionRoundPreparation: Sendable {
    case commit(ReconstructionJobCommitPlan)
    case model(ReconstructionPreparedModelRound)
}

protocol ReconstructionJobRoundMaterializing: Sendable {
    func prepare(
        snapshot: ReconstructionJobOrchestrationSnapshot
    ) async throws -> ReconstructionRoundPreparation
    func discardPreparedRound(
        snapshot: ReconstructionJobOrchestrationSnapshot,
        prepared: ReconstructionPreparedModelRound
    ) async
    func makeSourceCommitPlan(
        snapshot: ReconstructionJobOrchestrationSnapshot,
        prepared: ReconstructionPreparedModelRound,
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        source: ReconstructionSourceRevisionExecutionResult
    ) async throws -> ReconstructionJobCommitPlan
    func makeCommitPlan(
        snapshot: ReconstructionJobOrchestrationSnapshot,
        prepared: ReconstructionPreparedModelRound,
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        inference: ReconstructionInferenceExecutionResult,
        executions: [ReconstructionToolExecution]
    ) async throws -> ReconstructionJobCommitPlan
    func makeFailedModelPlan(
        snapshot: ReconstructionJobOrchestrationSnapshot,
        prepared: ReconstructionPreparedModelRound,
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        reason: ReconstructionJobCoordinatorFailure
    ) async throws -> ReconstructionJobCommitPlan
    func makeFinalCommitPlan(
        snapshot: ReconstructionJobOrchestrationSnapshot,
        prepared: ReconstructionPreparedModelRound,
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        synthesis: ReconstructionFinalSynthesisExecutionResult
    ) async throws -> ReconstructionJobCommitPlan
    func makeRecoveryPlan(
        snapshot: ReconstructionJobOrchestrationSnapshot,
        transitions: [ReconstructionTaskTransition]
    ) async throws -> ReconstructionJobCommitPlan
    func makeControlPlan(
        snapshot: ReconstructionJobOrchestrationSnapshot,
        reason: ReconstructionJobPauseReason
    ) async throws -> ReconstructionJobCommitPlan
}

extension ReconstructionJobRoundMaterializing {
    func makeSourceCommitPlan(
        snapshot: ReconstructionJobOrchestrationSnapshot,
        prepared: ReconstructionPreparedModelRound,
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        source: ReconstructionSourceRevisionExecutionResult
    ) async throws -> ReconstructionJobCommitPlan {
        throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
    }
}

/// Product round composition. The materializer supplies immutable, already captured DTO cuts;
/// this planner retains the model/tool/evidence authority and never receives Store or DB handles.
actor ReconstructionProductionJobRoundPlanner: ReconstructionJobRoundPlanning {
    private let materializer: any ReconstructionJobRoundMaterializing
    private let inference: any ReconstructionReadyInferenceCoordinating
    private let contextCompiler: ReconstructionContextCompiler
    private let broker: ReconstructionToolBroker
    private let registry = ReconstructionToolRegistry()
    private let replayOwner: ReconstructionDatabaseOwner?
    private let replayWorkspaceID: UUID?
    private var activeTasks: [UUID: Task<ReconstructionJobCommitPlan, Error>] = [:]

    init(
        materializer: any ReconstructionJobRoundMaterializing,
        inference: any ReconstructionReadyInferenceCoordinating,
        projectors: [any ReconstructionToolProjecting],
        contextCompiler: ReconstructionContextCompiler = .init(),
        replayOwner: ReconstructionDatabaseOwner? = nil,
        replayWorkspaceID: UUID? = nil
    ) {
        self.materializer = materializer
        self.inference = inference
        self.contextCompiler = contextCompiler
        self.replayOwner = replayOwner
        self.replayWorkspaceID = replayWorkspaceID
        broker = ReconstructionToolBroker(projectors: projectors)
    }

    func planRound(
        from snapshot: ReconstructionJobOrchestrationSnapshot
    ) async throws -> ReconstructionJobCommitPlan {
        let task = Task { try await self.executeRound(from: snapshot) }
        activeTasks[snapshot.jobID] = task
        defer { activeTasks[snapshot.jobID] = nil }
        return try await task.value
    }

    private func executeRound(
        from snapshot: ReconstructionJobOrchestrationSnapshot
    ) async throws -> ReconstructionJobCommitPlan {
        try Task.checkCancellation()
        let preparation = try await materializer.prepare(snapshot: snapshot)
        let prepared: ReconstructionPreparedModelRound
        switch preparation {
        case .commit(let plan):
            return plan
        case .model(let modelRound):
            prepared = modelRound
        }
        let scope: ReconstructionReplayScope?
        if let replayOwner, let replayWorkspaceID, let objective = prepared.objective {
            let running = snapshot.tasks.filter { $0.identity.kind == .modelRound && $0.state == .running }
            guard running.count == 1, let modelTask = running.first else {
                throw ReconstructionJobCoordinatorFailure.malformedOutput
            }
            scope = .init(owner: replayOwner, workspaceID: replayWorkspaceID, jobID: snapshot.jobID,
                taskID: modelTask.identity.taskID,
                logicalRoundIndex: snapshot.tasks.filter { $0.identity.kind == .modelRound && $0.state == .completed }.count,
                objectiveSHA256: objective.sha256, toolRequests: prepared.requests)
        } else { scope = nil }
        return try await ReconstructionReplayScope.$current.withValue(scope) {
            try await executePrepared(prepared, snapshot: snapshot)
        }
    }

    private func executePrepared(_ prepared: ReconstructionPreparedModelRound,
                                 snapshot: ReconstructionJobOrchestrationSnapshot) async throws -> ReconstructionJobCommitPlan {
        do {
            try Self.validatePreparedAuthority(
                prepared.authority,
                roundID: prepared.roundID,
                snapshot: snapshot
            )
            guard prepared.sourceRevisionRequest == nil || prepared.finalSynthesisRequest == nil else {
                throw ReconstructionJobCoordinatorFailure.malformedOutput
            }
            if let sourceRequest = prepared.sourceRevisionRequest {
                return try await executeSourceRevision(
                    request: sourceRequest, prepared: prepared, snapshot: snapshot
                )
            }
            if let finalRequest = prepared.finalSynthesisRequest {
                return try await executeFinalSynthesis(
                    request: finalRequest,
                    prepared: prepared,
                    snapshot: snapshot
                )
            }
            return try await executeInferenceRound(
                prepared: prepared,
                snapshot: snapshot
            )
        } catch {
            await materializer.discardPreparedRound(
                snapshot: snapshot,
                prepared: prepared
            )
            throw error
        }
    }

    private func executeSourceRevision(
        request: ReconstructionSourceRevisionRequest,
        prepared: ReconstructionPreparedModelRound,
        snapshot: ReconstructionJobOrchestrationSnapshot
    ) async throws -> ReconstructionJobCommitPlan {
        try Self.validateSourceRequest(request, prepared: prepared, snapshot: snapshot)
        let expectedContext = try ReconstructionSourceContextCompiler().compile(
            cut: prepared.evidenceCut, query: prepared.retrievalQuery, function: request.function,
            oracleSuiteSHA256: request.oracleSuiteSHA256, parentRevisionSHA256: request.parentRevisionSHA256
        )
        guard request.context == expectedContext else {
            throw ReconstructionJobCoordinatorFailure.malformedOutput
        }
        try Task.checkCancellation()
        let result = await inference.proposeSourceRevision(request: request)
        try Task.checkCancellation()
        switch result {
        case .notReady, .providerAuthorityChanged:
            throw ReconstructionJobCoordinatorFailure.modelUnavailable
        case .busy:
            throw ReconstructionJobCoordinatorFailure.inferenceBusy
        case .invalidRequest:
            throw ReconstructionJobCoordinatorFailure.malformedOutput
        case .failedWithoutTerminalAuthority(let failure):
            if failure == .cancelled {
                if Task.isCancelled { throw CancellationError() }
                throw ReconstructionJobCoordinatorFailure.modelUnavailable
            }
            if failure == .modelChanged { throw ReconstructionJobCoordinatorFailure.modelChanged }
            if case .retryableProviderFailure = failure {
                throw ReconstructionJobCoordinatorFailure.modelUnavailable
            }
            throw ReconstructionJobCoordinatorFailure.malformedOutput
        case .failedWithTerminalAuthority(let lease, let requestAuthority, let failure):
            guard requestAuthority.request == .sourceRevision(request) else {
                throw ReconstructionJobCoordinatorFailure.malformedOutput
            }
            if failure == .cancelled, Task.isCancelled { throw CancellationError() }
            return try await materializer.makeFailedModelPlan(
                snapshot: snapshot, prepared: prepared, lease: lease,
                requestAuthority: requestAuthority, reason: Self.commitFailure(for: failure)
            )
        case .finished(let lease, let requestAuthority, let source):
            guard requestAuthority.request == .sourceRevision(request),
                  requestAuthority.terminalReceipt == source.terminalReceipt,
                  source.terminalReceipt.status == .completed,
                  (try? source.candidate.validate(for: request)) != nil else {
                return try await materializer.makeFailedModelPlan(
                    snapshot: snapshot, prepared: prepared, lease: lease,
                    requestAuthority: requestAuthority, reason: .malformedOutput
                )
            }
            return try await materializer.makeSourceCommitPlan(
                snapshot: snapshot, prepared: prepared, lease: lease,
                requestAuthority: requestAuthority, source: source
            )
        }
    }

    static func validateSourceRequest(
        _ request: ReconstructionSourceRevisionRequest,
        prepared: ReconstructionPreparedModelRound,
        snapshot: ReconstructionJobOrchestrationSnapshot
    ) throws {
        try validatePreparedAuthority(prepared.authority, roundID: prepared.roundID, snapshot: snapshot)
        let matchingTasks = snapshot.tasks.filter { $0.identity.taskID == request.taskID }
        guard (try? request.validate()) != nil,
              prepared.projectorInput.authority == prepared.authority,
              prepared.sourceRevisionRequest == request, prepared.finalSynthesisRequest == nil,
              prepared.requests.isEmpty, prepared.allowedGapSubjects.isEmpty,
              prepared.allowedGapCategories.isEmpty,
              request.objective == prepared.objective,
              request.projectID == prepared.projectorInput.corpusManifest.reconstructionProjectID,
              request.jobID == snapshot.jobID, request.roundID == prepared.roundID,
              request.checkpointRevision == snapshot.checkpointRevision,
              request.corpusManifestSHA256 == snapshot.currentCorpusManifestSHA256,
              request.evidenceFrontierSHA256 == snapshot.evidenceFrontierSHA256,
              prepared.evidenceCut.corpusManifestSHA256 == snapshot.currentCorpusManifestSHA256,
              prepared.evidenceCut.frontierSHA256 == snapshot.evidenceFrontierSHA256,
              matchingTasks.count == 1, let task = matchingTasks.first,
              task.identity.jobID == snapshot.jobID, task.identity.kind == .modelRound,
              task.identity.operationContractIdentity == ReconstructionSourceRevisionEvidence.taskContract,
              task.identity.subject == .function(request.function),
              task.state == .running,
              (try? task.identity.verifyCanonicalIdentity()) != nil else {
            throw ReconstructionJobCoordinatorFailure.malformedOutput
        }
    }

    private func executeFinalSynthesis(
        request: ReconstructionFinalSynthesisRequest,
        prepared: ReconstructionPreparedModelRound,
        snapshot: ReconstructionJobOrchestrationSnapshot
    ) async throws -> ReconstructionJobCommitPlan {
        guard request.jobID == snapshot.jobID,
              request.checkpointRevision == snapshot.checkpointRevision,
              request.corpusManifestSHA256 == snapshot.currentCorpusManifestSHA256,
              request.evidenceFrontierSHA256 == snapshot.evidenceFrontierSHA256 else {
            throw ReconstructionJobCoordinatorFailure.malformedOutput
        }
        let result = await inference.synthesize(request: request, objective: prepared.objective)
        try Task.checkCancellation()
        switch result {
        case .notReady, .providerAuthorityChanged:
            throw ReconstructionJobCoordinatorFailure.modelUnavailable
        case .busy:
            throw ReconstructionJobCoordinatorFailure.inferenceBusy
        case .invalidRequest:
            throw ReconstructionJobCoordinatorFailure.malformedOutput
        case .failedWithoutTerminalAuthority(let failure):
            if failure == .cancelled {
                if Task.isCancelled { throw CancellationError() }
                throw ReconstructionJobCoordinatorFailure.modelUnavailable
            }
            if failure == .modelChanged { throw ReconstructionJobCoordinatorFailure.modelChanged }
            if case .retryableProviderFailure = failure {
                throw ReconstructionJobCoordinatorFailure.modelUnavailable
            }
            throw ReconstructionJobCoordinatorFailure.malformedOutput
        case .failedWithTerminalAuthority(
            let lease,
            let requestAuthority,
            let failure
        ):
            if failure == .cancelled, Task.isCancelled { throw CancellationError() }
            return try await materializer.makeFailedModelPlan(
                snapshot: snapshot,
                prepared: prepared,
                lease: lease,
                requestAuthority: requestAuthority,
                reason: Self.commitFailure(for: failure)
            )
        case .finished(let lease, let requestAuthority, let synthesis):
            return try await materializer.makeFinalCommitPlan(
                snapshot: snapshot,
                prepared: prepared,
                lease: lease,
                requestAuthority: requestAuthority,
                synthesis: synthesis
            )
        }
    }

    private func executeInferenceRound(
        prepared: ReconstructionPreparedModelRound,
        snapshot: ReconstructionJobOrchestrationSnapshot
    ) async throws -> ReconstructionJobCommitPlan {
        let context = try contextCompiler.compile(
            cut: prepared.evidenceCut,
            query: prepared.retrievalQuery,
            allowedGapSubjects: prepared.allowedGapSubjects,
            allowedGapCategories: prepared.allowedGapCategories
        )
        let handles = try registry.mintHandles(
            authority: prepared.authority,
            requests: prepared.requests
        )
        let request = ReconstructionInferenceRoundRequest(
            protocolVersion: Phase2ReconstructionAIWorkerWireCodec.protocolVersion,
            jobID: snapshot.jobID,
            checkpointRevision: snapshot.checkpointRevision,
            roundID: prepared.roundID,
            corpusManifestSHA256: prepared.authority.corpusManifestSHA256,
            evidenceFrontierSHA256: prepared.authority.evidenceFrontierSHA256,
            registryManifestSHA256: Phase2ReconstructionProtocolArtifacts.make()
                .toolRegistry.identity.sha256,
            context: context,
            handles: handles.map {
                .init(handleID: $0.handleID, operationID: $0.operationID)
            },
            transientAnalysis: prepared.objective == nil ? nil : prepared.transientAnalysis
        )
        try Task.checkCancellation()
        let readyResult = await inference.run(request: request, objective: prepared.objective)
        try Task.checkCancellation()
        switch readyResult {
        case .notReady, .providerAuthorityChanged:
            throw ReconstructionJobCoordinatorFailure.modelUnavailable
        case .busy:
            throw ReconstructionJobCoordinatorFailure.inferenceBusy
        case .invalidRequest:
            throw ReconstructionJobCoordinatorFailure.malformedOutput
        case .failedWithoutTerminalAuthority(let failure):
            if failure == .cancelled {
                if Task.isCancelled { throw CancellationError() }
                throw ReconstructionJobCoordinatorFailure.modelUnavailable
            }
            if failure == .modelChanged { throw ReconstructionJobCoordinatorFailure.modelChanged }
            if case .retryableProviderFailure = failure {
                throw ReconstructionJobCoordinatorFailure.modelUnavailable
            }
            throw ReconstructionJobCoordinatorFailure.malformedOutput
        case .failedWithTerminalAuthority(
            let lease,
            let requestAuthority,
            let failure
        ):
            if failure == .cancelled, Task.isCancelled { throw CancellationError() }
            return try await materializer.makeFailedModelPlan(
                snapshot: snapshot,
                prepared: prepared,
                lease: lease,
                requestAuthority: requestAuthority,
                reason: Self.commitFailure(for: failure)
            )
        case .finished(let lease, let requestAuthority, let outcome):
            guard outcome.candidate.jobID == snapshot.jobID,
                  outcome.candidate.checkpointRevision == snapshot.checkpointRevision,
                  outcome.candidate.roundID == prepared.roundID else {
                return try await materializer.makeFailedModelPlan(
                    snapshot: snapshot,
                    prepared: prepared,
                    lease: lease,
                    requestAuthority: requestAuthority,
                    reason: .malformedOutput
                )
            }
            let executions: [ReconstructionToolExecution]
            do {
                var resolvedGapIDsByHandleID: [UUID: [UUID]] = [:]
                var claimedGapIDs: Set<UUID> = []
                for claim in outcome.candidate.resolvedGaps {
                    guard outcome.candidate.selectedHandleIDs.contains(claim.handleID),
                          claimedGapIDs.insert(claim.gapID).inserted else {
                        throw ReconstructionJobCoordinatorFailure.malformedOutput
                    }
                    resolvedGapIDsByHandleID[claim.handleID, default: []].append(claim.gapID)
                }
                executions = try await broker.execute(
                    selectedHandleIDs: outcome.candidate.selectedHandleIDs,
                    offeredHandles: handles,
                    input: prepared.projectorInput,
                    resolvedGapIDsByHandleID: resolvedGapIDsByHandleID
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return try await materializer.makeFailedModelPlan(
                    snapshot: snapshot,
                    prepared: prepared,
                    lease: lease,
                    requestAuthority: requestAuthority,
                    reason: .malformedOutput
                )
            }
            try Task.checkCancellation()
            return try await materializer.makeCommitPlan(
                snapshot: snapshot,
                prepared: prepared,
                lease: lease,
                requestAuthority: requestAuthority,
                inference: outcome,
                executions: executions
            )
        }
    }

    static func validatePreparedAuthority(
        _ authority: ReconstructionToolAuthorityCut,
        roundID: UUID,
        snapshot: ReconstructionJobOrchestrationSnapshot
    ) throws {
        guard authority.jobID == snapshot.jobID,
              authority.checkpointRevision == snapshot.checkpointRevision,
              authority.roundID == roundID,
              authority.corpusManifestSHA256 == snapshot.currentCorpusManifestSHA256,
              authority.evidenceFrontierSHA256 == snapshot.evidenceFrontierSHA256 else {
            throw ReconstructionJobCoordinatorFailure.malformedOutput
        }
    }

    func planRecovery(
        from snapshot: ReconstructionJobOrchestrationSnapshot,
        transitions: [ReconstructionTaskTransition]
    ) async throws -> ReconstructionJobCommitPlan {
        try await materializer.makeRecoveryPlan(
            snapshot: snapshot,
            transitions: transitions
        )
    }

    func planControl(
        from snapshot: ReconstructionJobOrchestrationSnapshot,
        reason: ReconstructionJobPauseReason
    ) async throws -> ReconstructionJobCommitPlan {
        try await materializer.makeControlPlan(snapshot: snapshot, reason: reason)
    }

    func cancel(jobID: UUID) async {
        activeTasks[jobID]?.cancel()
    }

    private static func commitFailure(
        for failure: ReconstructionReadyInferenceFailure
    ) -> ReconstructionJobCoordinatorFailure {
        if case .retryableProviderFailure(let reason) = failure {
            return .retryableProviderFailure(reason?.rawValue ?? "providerCancelled")
        }
        if failure == .cancelled { return .retryableProviderFailure("providerCancelled") }
        return .malformedOutput
    }
}

enum ReconstructionCrashRecoveryPlan: Equatable, Sendable {
    case resume
    case recover([ReconstructionTaskTransition])
    case pause(ReconstructionJobPauseReason)
}

enum ReconstructionCrashRecovery {
    static func plan(
        snapshot: ReconstructionJobOrchestrationSnapshot
    ) -> ReconstructionCrashRecoveryPlan {
        guard snapshot.checkpointCorpusManifestSHA256
                == snapshot.currentCorpusManifestSHA256,
              snapshot.checkpointEvidenceFrontierSHA256
                == snapshot.evidenceFrontierSHA256 else {
            return .pause(.frontierMismatch)
        }
        let transitions = snapshot.tasks.compactMap { task -> ReconstructionTaskTransition? in
            guard task.state == .running else {
                return nil
            }
            // A receipt from a prior failed attempt cannot settle a newer running retry.
            // Atomic task/receipt commits make the current checkpoint the recovery cut.
            let successor = snapshot.terminalReceiptCheckpointRevisionsByTaskID[task.identity.taskID]
                    == snapshot.checkpointRevision
                ? snapshot.terminalReceiptStatesByTaskID[task.identity.taskID] ?? .pending
                : .pending
            return .init(
                taskID: task.identity.taskID,
                expectedState: .running,
                successorState: successor,
                diagnostic: nil
            )
        }.sorted { $0.taskID.uuidString.lowercased() < $1.taskID.uuidString.lowercased() }
        return transitions.isEmpty ? .resume : .recover(transitions)
    }
}

private final class ReconstructionJobControlCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func resolve(_ value: Bool) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = value
        let retainedWaiters = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in retainedWaiters {
            waiter.resume(returning: value)
        }
    }
}

actor ReconstructionJobCoordinator {
    private static let controlLogger = Logger(
        subsystem: "org.macscope.MacScope",
        category: "ReconstructionCoordinator"
    )

    typealias Sleep = @Sendable (UInt64) async throws -> Void

    enum ControlRestartTestStage: Sendable {
        case beforeRestart
        case afterDecision
    }

    /// Permit the already committed bounded analysis batch to settle before applying the
    /// no-progress gate. This is not progress itself and never authorizes another inference.
    static func hasPendingAuthorizedAnalysisRefresh(
        _ snapshot: ReconstructionJobOrchestrationSnapshot
    ) throws -> Bool {
        guard let next = try ReconstructionProductionRoundPlanBuilder
            .pendingRegularModelFrontier(in: snapshot.tasks),
              next.retrieve.identity.dependencyTaskIDs.count == 2,
              Set(snapshot.tasks.map(\.identity.taskID)).count == snapshot.tasks.count,
              snapshot.tasks.allSatisfy({ $0.identity.jobID == snapshot.jobID }) else { return false }
        let tasksByID = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.identity.taskID, $0) })
        let dependencies = next.retrieve.identity.dependencyTaskIDs.compactMap { tasksByID[$0] }
        guard let refresh = dependencies.first(where: { $0.identity.kind == .decompileMacScope }),
              refresh.state == .pending || refresh.state == .running,
              refresh.identity.operationContractIdentity == "reconstruction.decompileMacScope.v1",
              refresh.identity.dependencyTaskIDs.count == 2,
              case .function(let function)? = refresh.identity.subject,
              let predecessor = dependencies.first(where: { $0.identity.kind == .checkpoint }),
              predecessor.state == .completed,
              refresh.identity.dependencyTaskIDs.contains(predecessor.identity.taskID),
              let enumeration = refresh.identity.dependencyTaskIDs.compactMap({ tasksByID[$0] })
                .first(where: { $0.identity.kind == .enumerateFunctions }),
              enumeration.state == .completed,
              enumeration.identity.operationContractIdentity == "reconstruction.enumerateFunctions.v1",
              enumeration.identity.subject == .image(try ReconstructionImageCoordinate(
                artifact: function.artifact, image: function.image,
                analysisFingerprintSHA256: function.analysisFingerprintSHA256)),
              snapshot.tasks.filter({ $0.identity.kind == .decompileMacScope
                && $0.identity.dependencyTaskIDs.contains(predecessor.identity.taskID) }).count == 1,
              let prior = try ReconstructionProductionRoundPlanBuilder.regularModelFrontiers(in: snapshot.tasks)
                .first(where: { $0.checkpoint.identity.taskID == predecessor.identity.taskID }),
              prior.retrieve.state == .completed, prior.model.state == .completed,
              snapshot.terminalReceiptStatesByTaskID[prior.model.identity.taskID] == .completed else {
            return false
        }
        return true
    }

    private let persistence: any ReconstructionJobOrchestrationPersisting
    private let planner: any ReconstructionJobRoundPlanning
    private let publisher: any ReconstructionJobStatusPublishing
    private let scheduler: ReconstructionModelRoundScheduler
    private let inferenceBusyBackoff: ReconstructionInferenceBusyBackoffPolicy
    private let sleep: Sleep
    private let controlRestartTestHook:
        (@Sendable (ControlRestartTestStage) async -> Void)?
    private var activeTokens: [UUID: UUID] = [:]
    private struct PendingControl {
        let reason: ReconstructionJobPauseReason
        let authority: ReconstructionJobCommandAuthority?
        let completion: ReconstructionJobControlCompletion
    }

    private enum PendingControlApplication {
        case none
        case committed
        case rejected
    }

    private var pendingControls: [UUID: PendingControl] = [:]
    private var activeBackoffSleeps: [UUID: Task<Void, Error>] = [:]
    private var executionBudgetOwner: (owner: ReconstructionDatabaseOwner, workspaceID: UUID)?
    private var expiredExecutionBudgetTokens: Set<UUID> = []

    func configureExecutionBudget(owner: ReconstructionDatabaseOwner, workspaceID: UUID) {
        precondition(activeTokens.isEmpty && executionBudgetOwner == nil)
        executionBudgetOwner = (owner, workspaceID)
    }

    private func expireExecutionBudget(jobID: UUID, token: UUID) async {
        guard activeTokens[jobID] == token else { return }
        expiredExecutionBudgetTokens.insert(token)
        activeBackoffSleeps[jobID]?.cancel()
        await planner.cancel(jobID: jobID)
    }
    /// A coordinator belongs to one production JobSession. Transient retirement is therefore a
    /// one-way admission fence: a queued start/resume that reaches this actor late must not create
    /// a new token after its owning window has drained.
    private var transientlyRetiredJobIDs: Set<UUID> = []

    init(
        persistence: any ReconstructionJobOrchestrationPersisting,
        planner: any ReconstructionJobRoundPlanning,
        publisher: any ReconstructionJobStatusPublishing,
        scheduler: ReconstructionModelRoundScheduler = .init(),
        inferenceBusyBackoff: ReconstructionInferenceBusyBackoffPolicy = .standard,
        controlRestartTestHook: (@Sendable (ControlRestartTestStage) async -> Void)? = nil,
        sleep: @escaping Sleep = { delay in
            try await Task.sleep(nanoseconds: delay)
        }
    ) {
        self.persistence = persistence
        self.planner = planner
        self.publisher = publisher
        self.scheduler = scheduler
        self.inferenceBusyBackoff = inferenceBusyBackoff
        self.controlRestartTestHook = controlRestartTestHook
        self.sleep = sleep
    }

    func start(jobID: UUID) async {
        _ = await start(jobID: jobID, authority: nil)
    }

    @discardableResult
    func start(
        jobID: UUID,
        authority: ReconstructionJobCommandAuthority
    ) async -> Bool {
        await start(jobID: jobID, authority: Optional(authority))
    }

    private func start(
        jobID: UUID,
        authority: ReconstructionJobCommandAuthority?,
        expectedControlCompletion: ReconstructionJobControlCompletion? = nil
    ) async -> Bool {
        guard !transientlyRetiredJobIDs.contains(jobID),
              activeTokens[jobID] == nil,
              expectedControlCompletion.map({
                  pendingControls[jobID]?.completion === $0
              }) ?? true else { return false }
        let token = UUID()
        activeTokens[jobID] = token
        let hostActivity = ReconstructionExecutionActivity.shared.begin()
        defer {
            ReconstructionExecutionActivity.shared.end(hostActivity)
            if activeTokens[jobID] == token { activeTokens[jobID] = nil }
            // Controls may arrive while a final commit or publication suspends this actor.
            // Every run exit must release their waiters, including automatic pauses.
            rejectPendingControl(jobID: jobID)
        }
        let budgetWatchdog: Task<Void, Never>?
        if let budget = executionBudgetOwner {
            let remaining: Double
            do {
                remaining = try await budget.owner.beginExecutionBudget(workspaceID: budget.workspaceID,
                    jobID: jobID, activationID: token, policy: .forProcess())
            } catch {
                Self.controlLogger.error("Execution budget admission failed; job remains resumable")
                return false
            }
            if remaining == 0 { expiredExecutionBudgetTokens.insert(token) }
            budgetWatchdog = Task {
                do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
                await self.expireExecutionBudget(jobID: jobID, token: token)
            }
        } else { budgetWatchdog = nil }
        let result = await run(jobID: jobID, token: token, initialAuthority: authority)
        budgetWatchdog?.cancel()
        expiredExecutionBudgetTokens.remove(token)
        if let budget = executionBudgetOwner {
            do { try await budget.owner.finishExecutionBudget(workspaceID: budget.workspaceID,
                jobID: jobID, activationID: token) }
            catch { Self.controlLogger.error("Execution budget close failed; unclosed interval retained") }
        }
        return result
    }

    func pause(jobID: UUID) async {
        _ = await registerControl(.pausedByUser, jobID: jobID, authority: nil)
    }

    @discardableResult
    func pause(
        jobID: UUID,
        authority: ReconstructionJobCommandAuthority
    ) async -> Bool {
        await registerControl(.pausedByUser, jobID: jobID, authority: authority)
    }

    func resume(jobID: UUID) async {
        await start(jobID: jobID)
    }

    @discardableResult
    func resume(
        jobID: UUID,
        authority: ReconstructionJobCommandAuthority
    ) async -> Bool {
        await start(jobID: jobID, authority: authority)
    }

    /// Stops live execution for window/runtime retirement without changing durable job state.
    /// The permanent tombstone additionally fences a queued run that has not installed its token.
    func suspendWithoutDurableDisposition(jobID: UUID) async {
        transientlyRetiredJobIDs.insert(jobID)
        activeTokens[jobID] = nil
        if let pending = pendingControls.removeValue(forKey: jobID) {
            Self.logControlRejection(pending.reason, stage: "transient-suspension-released-control")
            pending.completion.resolve(false)
        }
        activeBackoffSleeps[jobID]?.cancel()
        await planner.cancel(jobID: jobID)
    }

    func cancel(jobID: UUID) async {
        _ = await registerControl(.cancelled, jobID: jobID, authority: nil)
    }

    @discardableResult
    func cancel(
        jobID: UUID,
        authority: ReconstructionJobCommandAuthority
    ) async -> Bool {
        await registerControl(.cancelled, jobID: jobID, authority: authority)
    }

    private func registerControl(
        _ reason: ReconstructionJobPauseReason,
        jobID: UUID,
        authority: ReconstructionJobCommandAuthority?
    ) async -> Bool {
        guard !transientlyRetiredJobIDs.contains(jobID) else {
            Self.logControlRejection(reason, stage: "transiently-retired-before-load")
            return false
        }
        guard let snapshot = try? await persistence.load(jobID: jobID) else {
            Self.logControlRejection(reason, stage: "persistence-load-failed")
            return false
        }
        guard !snapshot.currentDurableJobState.isTerminal else {
            Self.logControlRejection(reason, stage: "job-already-terminal")
            return false
        }
        guard authority.map({ Self.matches(snapshot, authority: $0) }) ?? true else {
            Self.logControlRejection(reason, stage: "command-authority-mismatch")
            return false
        }
        guard !transientlyRetiredJobIDs.contains(jobID) else {
            Self.logControlRejection(reason, stage: "transiently-retired-after-load")
            return false
        }

        if let existing = pendingControls[jobID], existing.reason == .cancelled,
           reason != .cancelled {
            Self.logControlRejection(reason, stage: "cancellation-control-already-pending")
            return false
        }
        if let displaced = pendingControls.removeValue(forKey: jobID) {
            Self.logControlRejection(displaced.reason, stage: "control-displaced-by-new-command")
            displaced.completion.resolve(false)
        }
        let completion = ReconstructionJobControlCompletion()
        let control = PendingControl(
            reason: reason,
            authority: authority,
            completion: completion
        )
        pendingControls[jobID] = control
        if reason == .pausedByUser,
           !(await ReconstructionInstalledPauseQualificationBarrier.waitIfRequested(
               reason: reason,
               jobID: jobID
           )) {
            Self.logControlRejection(reason, stage: "pause-qualification-barrier-rejected")
            rejectPendingControl(jobID: jobID, matching: completion)
            return false
        }
        guard pendingControls[jobID]?.completion === completion else {
            Self.logControlRejection(reason, stage: "control-superseded-during-planner-cancellation")
            return await completion.wait()
        }
        activeBackoffSleeps[jobID]?.cancel()
        await planner.cancel(jobID: jobID)
        guard pendingControls[jobID]?.completion === completion else {
            Self.logControlRejection(reason, stage: "control-superseded-after-planner-cancellation")
            return await completion.wait()
        }

        if activeTokens[jobID] == nil {
            Task { [weak self] in
                guard let self else {
                    completion.resolve(false)
                    return
                }
                if let testHook = await self.controlRestartTestHook {
                    await testHook(.beforeRestart)
                }
                let started = await self.start(
                    jobID: jobID,
                    authority: authority,
                    expectedControlCompletion: completion
                )
                if !started {
                    await self.rejectPendingControlIfNoActiveRun(
                        reason: reason,
                        jobID: jobID,
                        matching: completion
                    )
                    if let testHook = await self.controlRestartTestHook {
                        await testHook(.afterDecision)
                    }
                }
            }
        }
        return await completion.wait()
    }

    private static func logControlRejection(
        _ reason: ReconstructionJobPauseReason,
        stage: String
    ) {
        controlLogger.error(
            "Control \(reason.rawValue, privacy: .public) rejected at \(stage, privacy: .public)"
        )
    }

    private func rejectPendingControlIfNoActiveRun(
        reason: ReconstructionJobPauseReason,
        jobID: UUID,
        matching completion: ReconstructionJobControlCompletion
    ) {
        guard pendingControls[jobID]?.completion === completion else { return }
        guard activeTokens[jobID] == nil else {
            // The restoration/start call may have won actor scheduling after the control
            // observed no token and queued its own start. Keep the pending control for that
            // run's next boundary instead of rejecting it because our redundant start lost.
            Self.controlLogger.error(
                "Control \(reason.rawValue, privacy: .public) start delegated to active run"
            )
            return
        }
        Self.logControlRejection(reason, stage: "control-run-start-rejected")
        rejectPendingControl(jobID: jobID, matching: completion)
    }

    private func run(
        jobID: UUID,
        token: UUID,
        initialAuthority: ReconstructionJobCommandAuthority?
    ) async -> Bool {
        var inferenceBusyAttempts = 0
        var inferenceBusyElapsedNanoseconds: UInt64 = 0
        var admissionAuthority = initialAuthority
        var hasCommittedCommandEffect = false
        // Explicit Resume grants one new attempt. Restoring the paused phase may itself
        // require several commits before the model frontier is executed.
        var retryStalledModelRound = initialAuthority?.expectedJobState == .paused
        // A fresh token may recover persisted work left running by a prior process/run. Once
        // admitted, running leaves can be our own committed model activation, not crash debris.
        var needsAdmissionRecovery = true
        while activeTokens[jobID] == token {
            do {
                let snapshot = try await persistence.load(jobID: jobID)
                guard activeTokens[jobID] == token,
                      !transientlyRetiredJobIDs.contains(jobID) else { return false }
                if let expected = admissionAuthority {
                    guard Self.matches(snapshot, authority: expected) else { return false }
                    admissionAuthority = nil
                }
                guard !snapshot.currentDurableJobState.isTerminal else {
                    return initialAuthority == nil
                }
                guard snapshot.consecutiveModelRoundsWithoutEvidence >= 0 else {
                    throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                }
                switch try await applyPendingControlIfPresent(
                    jobID: jobID,
                    snapshot: snapshot
                ) {
                case .none:
                    break
                case .committed:
                    return true
                case .rejected:
                    return false
                }
                if expiredExecutionBudgetTokens.contains(token) {
                    guard snapshot.currentDurableJobState != .paused else { return false }
                    try await commitControl(.evidenceStalled, snapshot: snapshot)
                    return true
                }
                if snapshot.tasks.contains(where: { $0.diagnostic?.text == ReconstructionTaskBudgetPause.diagnostic }) {
                    // Resuming cannot grow an immutable exhausted task budget. Retain the
                    // truthful pause and allow cancellation, rather than failing the job.
                    guard snapshot.currentDurableJobState != .paused else { return false }
                    try await commitControl(.evidenceStalled, snapshot: snapshot)
                    return true
                }
                if !retryStalledModelRound,
                   snapshot.currentDurableJobState != .paused,
                   snapshot.consecutiveModelRoundsWithoutEvidence
                    >= snapshot.maximumRoundsWithoutEvidence,
                   try !Self.hasPendingAuthorizedAnalysisRefresh(snapshot),
                   try ReconstructionProductionModelRoundBudgetAuthority
                    .hasPendingRegularRound(snapshot.tasks) {
                    // Automatic execution pauses at the frozen bound. An explicit Resume
                    // grants one retry while retaining the historical no-evidence count.
                    try await commitControl(.evidenceStalled, snapshot: snapshot)
                    return true
                }
                let recovery = ReconstructionCrashRecovery.plan(snapshot: snapshot)
                let recoverInterruptedTasks = needsAdmissionRecovery
                needsAdmissionRecovery = false
                switch recovery {
                case .pause(let reason):
                    // Frontier authority remains checked on every live iteration.
                    try await commitControl(reason, snapshot: snapshot)
                    return true
                case .recover(let transitions):
                    guard recoverInterruptedTasks else { break }
                    let plan = try await planner.planRecovery(
                        from: snapshot,
                        transitions: transitions
                    )
                    let receipt = try await commitValidated(plan, snapshot: snapshot)
                    hasCommittedCommandEffect = true
                    await publisher.publish(receipt)
                    continue
                case .resume:
                    break
                }

                let plan = try await scheduler.withAdmission(.init(
                    jobID: snapshot.jobID,
                    jobCreationOrder: snapshot.jobCreationOrder,
                    checkpointRevision: snapshot.checkpointRevision
                )) {
                    try await self.planner.planRound(from: snapshot)
                }
                guard activeTokens[jobID] == token else {
                    rejectPendingControl(jobID: jobID)
                    return false
                }
                switch try await applyPendingControlIfPresent(
                    jobID: jobID,
                    snapshot: snapshot
                ) {
                case .none:
                    break
                case .committed:
                    return true
                case .rejected:
                    return false
                }
                let receipt = try await commitValidated(plan, snapshot: snapshot)
                hasCommittedCommandEffect = true
                await publisher.publish(receipt)
                inferenceBusyAttempts = 0
                inferenceBusyElapsedNanoseconds = 0

                switch plan.disposition {
                case .continue, .advancePhase:
                    let schedulesAnotherRegularRound = try
                        ReconstructionProductionModelRoundBudgetAuthority
                            .planSchedulesAnotherRegularRound(plan, from: snapshot)
                    guard schedulesAnotherRegularRound else { continue }
                    retryStalledModelRound = false
                    // Reload after the commit and enforce the budget exclusively from the
                    // persisted task/receipt graph. This makes crash/reopen behavior identical
                    // to the uninterrupted path and prevents a transient accepted-count hint
                    // from becoming durable authority.
                    let current = try await persistence.load(jobID: jobID)
                    if current.consecutiveModelRoundsWithoutEvidence
                        >= current.maximumRoundsWithoutEvidence,
                       try !Self.hasPendingAuthorizedAnalysisRefresh(current) {
                        try await commitControl(.evidenceStalled, snapshot: current)
                        return true
                    }
                case .completed, .paused, .cancelled, .failed:
                    return true
                }
            } catch let failure as ReconstructionJobCoordinatorFailure {
                let reason: String
                switch failure {
                case .modelUnavailable: reason = "modelUnavailable"
                case .modelChanged: reason = "modelChanged"
                case .inferenceBusy: reason = "inferenceBusy"
                case .malformedOutput: reason = "malformedOutput"
                case .retryableProviderFailure: reason = "retryableProviderFailure"
                case .invalidCommitPlan: reason = "invalidCommitPlan"
                case .checkpointConflict: reason = "checkpointConflict"
                case .jobNotFound: reason = "jobNotFound"
                }
                Self.controlLogger.error("Round rejected: \(reason, privacy: .public)")
                guard activeTokens[jobID] == token else {
                    rejectPendingControl(jobID: jobID)
                    return false
                }
                switch failure {
                case .inferenceBusy:
                    guard let delay = inferenceBusyBackoff.nextDelay(
                        completedAttempts: inferenceBusyAttempts,
                        elapsedNanoseconds: inferenceBusyElapsedNanoseconds
                    ) else {
                        guard let snapshot = try? await fallbackSnapshot(
                            jobID: jobID,
                            commandAuthority: initialAuthority,
                            hasCommittedCommandEffect: hasCommittedCommandEffect
                        ) else {
                            rejectPendingControl(jobID: jobID)
                            return false
                        }
                        return await commitFallbackControl(
                            .inferenceBusy,
                            snapshot: snapshot,
                            jobID: jobID
                        )
                    }
                    do {
                        try await sleepForBusyBackoff(delay, jobID: jobID)
                    } catch is CancellationError {
                        guard activeTokens[jobID] == token else {
                            rejectPendingControl(jobID: jobID)
                            return false
                        }
                        guard let snapshot = try? await fallbackSnapshot(
                            jobID: jobID,
                            commandAuthority: initialAuthority,
                            hasCommittedCommandEffect: hasCommittedCommandEffect
                        ) else {
                            rejectPendingControl(jobID: jobID)
                            return false
                        }
                        let application = (try? await applyPendingControlIfPresent(
                            jobID: jobID,
                            snapshot: snapshot
                        )) ?? .rejected
                        switch application {
                        case .committed:
                            return true
                        case .rejected:
                            return false
                        case .none:
                            break
                        }
                        return await commitFallbackControl(
                            // Host/task interruption is resumable. An explicit user Cancel was
                        // handled above by its durable pending control and remains abandonment.
                        .evidenceStalled,
                            snapshot: snapshot,
                            jobID: jobID
                        )
                    } catch {
                        guard let snapshot = try? await fallbackSnapshot(
                            jobID: jobID,
                            commandAuthority: initialAuthority,
                            hasCommittedCommandEffect: hasCommittedCommandEffect
                        ) else {
                            rejectPendingControl(jobID: jobID)
                            return false
                        }
                        return await commitFallbackControl(
                            .failed,
                            snapshot: snapshot,
                            jobID: jobID
                        )
                    }
                    inferenceBusyAttempts += 1
                    inferenceBusyElapsedNanoseconds += delay
                    continue
                case .modelUnavailable, .retryableProviderFailure:
                    guard let snapshot = try? await fallbackSnapshot(
                        jobID: jobID,
                        commandAuthority: initialAuthority,
                        hasCommittedCommandEffect: hasCommittedCommandEffect
                    ) else {
                        rejectPendingControl(jobID: jobID)
                        return false
                    }
                    return await commitFallbackControl(
                        .modelUnavailable,
                        snapshot: snapshot,
                        jobID: jobID
                    )
                case .modelChanged:
                    // Said once: the durable failure carries the typed reason; no retry/pause.
                    guard let snapshot = try? await fallbackSnapshot(
                        jobID: jobID,
                        commandAuthority: initialAuthority,
                        hasCommittedCommandEffect: hasCommittedCommandEffect
                    ) else {
                        rejectPendingControl(jobID: jobID)
                        return false
                    }
                    return await commitFallbackControl(
                        .modelChanged,
                        snapshot: snapshot,
                        jobID: jobID
                    )
                case .malformedOutput, .invalidCommitPlan:
                    guard let snapshot = try? await fallbackSnapshot(
                        jobID: jobID,
                        commandAuthority: initialAuthority,
                        hasCommittedCommandEffect: hasCommittedCommandEffect
                    ) else {
                        rejectPendingControl(jobID: jobID)
                        return false
                    }
                    return await commitFallbackControl(
                        .failed,
                        snapshot: snapshot,
                        jobID: jobID
                    )
                case .checkpointConflict:
                    rejectPendingControl(jobID: jobID)
                    return false
                case .jobNotFound:
                    rejectPendingControl(jobID: jobID)
                    return false
                }
            } catch let failure as ReconstructionSourceOriginalRecoveryFailure {
                let failureLabel: String
                switch failure {
                case .unavailable: failureLabel = "unavailable"
                case .authorityMismatch: failureLabel = "authorityMismatch"
                case .retired: failureLabel = "retired"
                }
                Self.controlLogger.error("Source recovery rejected: \(failureLabel, privacy: .public)")
                guard activeTokens[jobID] == token else {
                    rejectPendingControl(jobID: jobID)
                    return false
                }
                guard let snapshot = try? await fallbackSnapshot(jobID: jobID,
                    commandAuthority: initialAuthority,
                    hasCommittedCommandEffect: hasCommittedCommandEffect) else {
                    rejectPendingControl(jobID: jobID)
                    return false
                }
                guard activeTokens[jobID] == token else {
                    rejectPendingControl(jobID: jobID)
                    return false
                }
                switch (try? await applyPendingControlIfPresent(jobID: jobID, snapshot: snapshot)) ?? .rejected {
                case .committed: return true
                case .rejected: return false
                case .none: break
                }
                let reason: ReconstructionJobPauseReason
                switch failure {
                case .unavailable: reason = .evidenceStalled
                case .authorityMismatch, .retired: reason = .failed
                }
                return await commitFallbackControl(reason, snapshot: snapshot, jobID: jobID)
            } catch is CancellationError {
                guard activeTokens[jobID] == token else {
                    rejectPendingControl(jobID: jobID)
                    return false
                }
                guard let snapshot = try? await fallbackSnapshot(
                    jobID: jobID,
                    commandAuthority: initialAuthority,
                    hasCommittedCommandEffect: hasCommittedCommandEffect
                ) else {
                    rejectPendingControl(jobID: jobID)
                    return false
                }
                switch (try? await applyPendingControlIfPresent(
                    jobID: jobID,
                    snapshot: snapshot
                )) ?? .rejected {
                case .committed:
                    return true
                case .rejected:
                    return false
                case .none:
                    return await commitFallbackControl(
                        .cancelled,
                        snapshot: snapshot,
                        jobID: jobID
                    )
                }
            } catch {
                let errorType = String(describing: type(of: error))
                Self.controlLogger.error("Round rejected by error type: \(errorType, privacy: .public)")
                // Closed engine error types whose payloads are SQLite messages, table/field names,
                // enum labels or evidence UUIDs; never user binary bytes or prompt text.
                if error is WorkspaceDatabase.DatabaseError || error is ReconstructionContextCompilerError
                    || error is ReconstructionReplayError || error is ReconstructionRetrievalError {
                    let detail = String(String(describing: error).prefix(1_024))
                    Self.controlLogger.error("Round rejection detail: \(detail, privacy: .public)")
                }
                if let failure = error as? ReconstructionProductionReceiptPlanAuthorError {
                    // This enum has no associated values; its label cannot contain user input.
                    let reason = String(describing: failure)
                    Self.controlLogger.error("Receipt plan rejected: \(reason, privacy: .public)")
                }
                guard activeTokens[jobID] == token else {
                    rejectPendingControl(jobID: jobID)
                    return false
                }
                guard let snapshot = try? await fallbackSnapshot(
                    jobID: jobID,
                    commandAuthority: initialAuthority,
                    hasCommittedCommandEffect: hasCommittedCommandEffect
                ) else {
                    rejectPendingControl(jobID: jobID)
                    return false
                }
                return await commitFallbackControl(
                    .failed,
                    snapshot: snapshot,
                    jobID: jobID
                )
            }
        }
        rejectPendingControl(jobID: jobID)
        return false
    }

    private func applyPendingControlIfPresent(
        jobID: UUID,
        snapshot: ReconstructionJobOrchestrationSnapshot
    ) async throws -> PendingControlApplication {
        guard let pending = pendingControls.removeValue(forKey: jobID) else { return .none }
        guard pending.authority.map({ Self.matches(snapshot, authority: $0) }) ?? true else {
            pending.completion.resolve(false)
            return .rejected
        }
        do {
            try await commitControl(pending.reason, snapshot: snapshot)
            pending.completion.resolve(true)
            return .committed
        } catch {
            pending.completion.resolve(false)
            throw error
        }
    }

    /// Error handling may author a durable pause/failure only against the same cut that admitted
    /// the command. Once a prior effect has committed, the coordinator owns the successor loop;
    /// before that boundary, a changed cut is a command rejection rather than a retry.
    private func fallbackSnapshot(
        jobID: UUID,
        commandAuthority: ReconstructionJobCommandAuthority?,
        hasCommittedCommandEffect: Bool
    ) async throws -> ReconstructionJobOrchestrationSnapshot {
        let snapshot = try await persistence.load(jobID: jobID)
        if !hasCommittedCommandEffect,
           let commandAuthority,
           !Self.matches(snapshot, authority: commandAuthority) {
            throw ReconstructionJobCoordinatorFailure.checkpointConflict
        }
        return snapshot
    }

    private func commitFallbackControl(
        _ reason: ReconstructionJobPauseReason,
        snapshot: ReconstructionJobOrchestrationSnapshot,
        jobID: UUID
    ) async -> Bool {
        do {
            try await commitControl(reason, snapshot: snapshot)
            return true
        } catch {
            rejectPendingControl(jobID: jobID)
            return false
        }
    }

    private func rejectPendingControl(
        jobID: UUID,
        matching completion: ReconstructionJobControlCompletion? = nil
    ) {
        guard let pending = pendingControls[jobID],
              completion.map({ $0 === pending.completion }) ?? true else { return }
        pendingControls[jobID] = nil
        pending.completion.resolve(false)
    }

    private static func matches(
        _ snapshot: ReconstructionJobOrchestrationSnapshot,
        authority: ReconstructionJobCommandAuthority
    ) -> Bool {
        snapshot.jobID == authority.jobID
            && snapshot.currentDurableJobState == authority.expectedJobState
            && snapshot.checkpointID == authority.checkpointID
            && snapshot.checkpointRevision == authority.checkpointRevision
            && snapshot.currentCorpusManifestSHA256 == authority.corpusManifestSHA256
            && snapshot.evidenceFrontierSHA256 == authority.evidenceFrontierSHA256
    }

    private func sleepForBusyBackoff(_ delay: UInt64, jobID: UUID) async throws {
        let task = Task { try await sleep(delay) }
        activeBackoffSleeps[jobID] = task
        defer { activeBackoffSleeps[jobID] = nil }
        try await task.value
    }

    private func commitControl(
        _ reason: ReconstructionJobPauseReason,
        snapshot: ReconstructionJobOrchestrationSnapshot
    ) async throws {
        let plan = try await planner.planControl(from: snapshot, reason: reason)
        let receipt = try await commitValidated(plan, snapshot: snapshot)
        await publisher.publish(receipt)
    }

    private func commitValidated(
        _ plan: ReconstructionJobCommitPlan,
        snapshot: ReconstructionJobOrchestrationSnapshot
    ) async throws -> ReconstructionJobCommitReceipt {
        guard plan.successorRevision == snapshot.checkpointRevision + 1,
              plan.acceptedEvidenceCount >= 0 else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        let receipt = try await persistence.commit(plan, for: snapshot)
        if let mutation = plan.mutation { ReconstructionResumeFaultInjection.shared.committed(mutation) }
        return receipt
    }
}

/// Private, explicit installed-XCUITest barrier for observing pending Pause before its durable
/// checkpoint commits. Ordinary execution never opens a path or waits: both opt-in variables must
/// be present, and the root must be one canonical, caller-owned directory immediately below
/// `/private/tmp` or the fixed installed runner container's private tmp. The create-only
/// receipt/token protocol prevents a stale file from manufacturing arrival or release.
enum ReconstructionInstalledPauseQualificationBarrier {
    static let rootEnvironmentKey = "MACSCOPE_WS24_RECONSTRUCTION_PAUSE_BARRIER_ROOT"
    static let candidateSHA256EnvironmentKey =
        "MACSCOPE_WS24_RECONSTRUCTION_PAUSE_CANDIDATE_SHA256"
    static let runEnvironmentKey = "MACSCOPE_WS24_RUN_INSTALLED_XCUITEST"
    static let arrivalFilename = "pause-control-arrived.json"
    static let releaseFilename = "pause-control-release"
    static let maximumWaitNanoseconds: UInt64 = 15_000_000_000
    private static let pollingNanoseconds: UInt64 = 20_000_000
    private static let rootPrefix = "MacScope-Task10-PauseBarrier-"

    private enum ReleaseStatus {
        case absent
        case valid
        case invalid
    }

    static func waitIfRequested(
        reason: ReconstructionJobPauseReason,
        jobID: UUID,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableURL: URL? = Bundle.main.executableURL
    ) async -> Bool {
        guard reason == .pausedByUser else { return true }
        let isOptedIn = truthy(environment[runEnvironmentKey])
        let hasDedicatedConfiguration = environment[rootEnvironmentKey] != nil
            || environment[candidateSHA256EnvironmentKey] != nil
        guard isOptedIn, hasDedicatedConfiguration else {
            return true
        }
        guard let suppliedRoot = environment[rootEnvironmentKey],
              !suppliedRoot.isEmpty,
              let expectedCandidateSHA256 = environment[candidateSHA256EnvironmentKey],
              isLowercaseSHA256(expectedCandidateSHA256),
              let executableURL,
              let observedCandidateSHA256 = try? sha256Hex(of: executableURL),
              observedCandidateSHA256 == expectedCandidateSHA256,
              let rootDescriptor = ReconstructionInstalledQualificationBarrierRoot.openOwnedRoot(
                  suppliedRoot, prefix: rootPrefix
              ) else { return false }
        defer { Darwin.close(rootDescriptor) }

        guard releaseStatus(rootDescriptor: rootDescriptor) == .absent,
              createArrival(
                  rootDescriptor: rootDescriptor,
                  jobID: jobID,
                  candidateSHA256: observedCandidateSHA256
              ) else {
            return false
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .nanoseconds(Int64(maximumWaitNanoseconds)))
        while clock.now < deadline {
            switch releaseStatus(rootDescriptor: rootDescriptor) {
            case .valid:
                return true
            case .invalid:
                return false
            case .absent:
                do {
                    try await Task.sleep(nanoseconds: pollingNanoseconds)
                } catch {
                    return false
                }
            }
        }
        return false
    }

    private static func truthy(_ value: String?) -> Bool {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on": true
        default: false
        }
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64
            && value.unicodeScalars.allSatisfy {
                (48...57).contains($0.value) || (97...102).contains($0.value)
            }
    }

    private static func createArrival(
        rootDescriptor: Int32,
        jobID: UUID,
        candidateSHA256: String
    ) -> Bool {
        let descriptor = arrivalFilename.withCString {
            Darwin.openat(
                rootDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        let receipt = "{\"candidateSHA256\":\"\(candidateSHA256)\","
            + "\"jobID\":\"\(jobID.uuidString.lowercased())\","
            + "\"kind\":\"pause\",\"pid\":\(ProcessInfo.processInfo.processIdentifier)}\n"
        let payload = Data(receipt.utf8)
        let didWrite = payload.withUnsafeBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress else { return false }
            var written = 0
            while written < buffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    buffer.count - written
                )
                guard result > 0 else { return false }
                written += result
            }
            return true
        }
        return didWrite && Darwin.fsync(descriptor) == 0
    }

    private static func releaseStatus(rootDescriptor: Int32) -> ReleaseStatus {
        let descriptor = releaseFilename.withCString {
            Darwin.openat(
                rootDescriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        guard descriptor >= 0 else {
            return errno == ENOENT ? .absent : .invalid
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_nlink == 1,
              metadata.st_size == 0,
              metadata.st_mode & 0o077 == 0 else {
            return .invalid
        }
        return .valid
    }

    private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct ReconstructionDatabaseJobPersistence: ReconstructionJobOrchestrationPersisting {
    let workspaceID: UUID
    let owner: ReconstructionDatabaseOwner

    func eligibleJobIDs() async throws -> [UUID] {
        let state = try await owner.load(workspaceID: workspaceID)
        return state.jobs.filter { !$0.state.isTerminal && $0.state != .paused }
            .map(\.jobID)
    }

    func load(jobID: UUID) async throws -> ReconstructionJobOrchestrationSnapshot {
        // Capture the complete project/job authority under one database transaction. In
        // particular, the current evidence frontier must be derived from the project-wide rows,
        // not copied from this job's frozen checkpoint: a sibling job can advance the shared
        // frontier while this job is interrupted. Keeping both values from this one cut lets
        // crash recovery pause with `frontierMismatch` before invoking any planner.
        let rows = try await owner.captureProductionRoundRows(
            workspaceID: workspaceID,
            jobID: jobID
        )
        let job = rows.job
        let checkpoint = rows.checkpoint
        guard let persistedCreationOrder = job.creationOrdinal else {
            throw ReconstructionJobCoordinatorFailure.jobNotFound
        }
        let currentEvidenceFrontierSHA256 = try Self.currentEvidenceFrontierSHA256(
            rows: rows
        )
        let tasks = rows.tasks
        let toolReceipts = rows.toolReceipts
        let modelReceipts = rows.modelReceipts
        let taskCompletionAuthorities = rows.taskCompletionAuthorities
        let terminalAuthority = try Self.terminalReceiptAuthority(
            toolReceipts: toolReceipts,
            modelReceipts: modelReceipts
        )
        let consecutiveModelRoundsWithoutEvidence = try
            ReconstructionProductionModelRoundBudgetAuthority
                .consecutiveRoundsWithoutEvidence(
                    jobID: jobID,
                    tasks: tasks,
                    toolReceipts: toolReceipts,
                    modelReceipts: modelReceipts,
                    taskCompletionAuthorities: taskCompletionAuthorities
                )
        return .init(
            jobID: jobID,
            jobCreationOrder: persistedCreationOrder,
            checkpointID: checkpoint.checkpointID,
            checkpointRevision: checkpoint.revision,
            checkpointCorpusManifestSHA256: checkpoint.corpusManifestSHA256,
            checkpointEvidenceFrontierSHA256: checkpoint.evidenceFrontierSHA256,
            currentCorpusManifestSHA256: rows.manifest.canonicalSHA256,
            evidenceFrontierSHA256: currentEvidenceFrontierSHA256,
            currentDurableJobState: job.state,
            pauseContext: job.pauseContext,
            maximumRoundsWithoutEvidence: job.budget.maxRounds,
            tasks: tasks,
            terminalReceiptStatesByTaskID: terminalAuthority.states,
            consecutiveModelRoundsWithoutEvidence: consecutiveModelRoundsWithoutEvidence,
            terminalReceiptCheckpointRevisionsByTaskID: terminalAuthority.revisions
        )
    }

    private static func currentEvidenceFrontierSHA256(
        rows: ReconstructionProductionRoundRows
    ) throws -> String {
        let projection = try ReconstructionEvidenceProjector().project(
            records: rows.evidence,
            relations: rows.evidenceRelations.filter { $0.kind != .resolvesGap },
            authority: rows.freshnessAuthority
        )
        var classifications: [UUID: ReconstructionEvidenceClassification] = [:]
        classifications.reserveCapacity(projection.records.count)
        for projected in projection.records {
            guard classifications.updateValue(
                projected.classification,
                forKey: projected.record.evidenceID
            ) == nil else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
        }
        return try ReconstructionEvidenceFrontier.canonicalSHA256(
            corpusManifestSHA256: rows.manifest.canonicalSHA256,
            records: rows.evidence,
            projectedClassificationsByEvidenceID: classifications,
            relations: rows.evidenceRelations,
            gaps: rows.evidenceGaps,
            checkpointRevisionsByID: rows.checkpointRevisionsByID
        )
    }

    func commit(
        _ plan: ReconstructionJobCommitPlan,
        for snapshot: ReconstructionJobOrchestrationSnapshot
    ) async throws -> ReconstructionJobCommitReceipt {
        guard let mutation = plan.mutation else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        let committed: ReconstructionCommittedCheckpoint
        do {
            committed = try await owner.commit(
                workspaceID: workspaceID,
                mutation: mutation
            )
        } catch WorkspaceDatabase.DatabaseError.reconstructionCheckpointConflict(_) {
            throw ReconstructionJobCoordinatorFailure.checkpointConflict
        }
        guard committed.checkpoint.revision == plan.successorRevision else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        return .init(
            jobID: snapshot.jobID,
            checkpointRevision: committed.checkpoint.revision,
            evidenceFrontierSHA256: committed.checkpoint.evidenceFrontierSHA256,
            disposition: plan.disposition,
            committedCheckpoint: committed
        )
    }

    private static func taskState(
        for terminal: ReconstructionReceiptTerminalState
    ) -> ReconstructionTaskState {
        switch terminal {
        case .completed, .truncated: .completed
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }

    /// Rebuilds crash-recovery authority without allowing receipt ordering to choose between
    /// contradictory tool outcomes. Package/database admission enforces the same invariant; this
    /// remains a defense-in-depth boundary for any future persistence implementation.
    static func terminalReceiptStates(
        toolReceipts: [ReconstructionToolReceipt],
        modelReceipts: [ReconstructionModelReceipt]
    ) throws -> [UUID: ReconstructionTaskState] {
        try terminalReceiptAuthority(toolReceipts: toolReceipts, modelReceipts: modelReceipts).states
    }

    static func terminalReceiptAuthority(
        toolReceipts: [ReconstructionToolReceipt],
        modelReceipts: [ReconstructionModelReceipt]
    ) throws -> (states: [UUID: ReconstructionTaskState], revisions: [UUID: UInt64]) {
        var terminalStates: [UUID: ReconstructionTaskState] = [:]
        var terminalRevisions: [UUID: UInt64] = [:]
        for receipt in toolReceipts {
            let state = taskState(for: receipt.terminalState)
            guard terminalStates.updateValue(state, forKey: receipt.taskID) == nil else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            terminalRevisions[receipt.taskID] = receipt.checkpointRevision
        }
        for receipt in modelReceipts {
            let state = taskState(for: receipt.terminalState)
            if let revision = terminalRevisions[receipt.taskID], revision > receipt.checkpointRevision { continue }
            if terminalRevisions[receipt.taskID] == receipt.checkpointRevision,
               let existing = terminalStates[receipt.taskID], existing != state {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            terminalStates[receipt.taskID] = state
            terminalRevisions[receipt.taskID] = receipt.checkpointRevision
        }
        return (terminalStates, terminalRevisions)
    }
}

extension ReconstructionDatabaseJobPersistence:
    ReconstructionNativeDecompilerDurableJobValidating
{
    func validateActiveDurableJobID(_ jobID: UUID) async throws {
        let state = try await owner.load(workspaceID: workspaceID)
        guard let job = state.jobs.first(where: { $0.jobID == jobID }),
              Self.acceptsNativeAdmissionBinding(
                state: job.state,
                pauseContext: job.pauseContext
              ) else {
            throw ReconstructionJobCoordinatorFailure.jobNotFound
        }
    }

    /// A paused durable job may bind its job-scoped admission before `resume` advances the
    /// checkpoint, but only when the persisted pause context names a valid active resume target.
    /// Terminal states and malformed/absent pause authority remain rejected.
    static func acceptsNativeAdmissionBinding(
        state: ReconstructionJobState,
        pauseContext: ReconstructionJobPauseContext?
    ) -> Bool {
        if ReconstructionJobState.activeStates.contains(state) {
            return pauseContext == nil
        }
        guard state == .paused,
              let pauseContext,
              ReconstructionJobState.activeStates.contains(pauseContext.resumeTarget) else {
            return false
        }
        do {
            try ReconstructionJobStateMachine.transition(
                from: .paused,
                to: pauseContext.resumeTarget,
                resumeTarget: pauseContext.resumeTarget
            )
            return true
        } catch {
            return false
        }
    }
}
