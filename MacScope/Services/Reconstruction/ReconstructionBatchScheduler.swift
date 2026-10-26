import Foundation

struct ReconstructionBatchAuthority: Equatable, Sendable {
    let jobID: UUID
    let checkpointID: UUID
    let checkpointRevision: UInt64
    let corpusManifestSHA256: String

    init(
        jobID: UUID,
        checkpointID: UUID,
        checkpointRevision: UInt64,
        corpusManifestSHA256: String
    ) throws {
        try ReconstructionValidation.requireSHA256(
            corpusManifestSHA256,
            field: "reconstruction batch corpus manifest"
        )
        self.jobID = jobID
        self.checkpointID = checkpointID
        self.checkpointRevision = checkpointRevision
        self.corpusManifestSHA256 = corpusManifestSHA256
    }
}

struct ReconstructionBatchBudget: Equatable, Sendable {
    let maximumTasks: Int
    let maximumConcurrentTasks: Int

    init(maximumTasks: Int, maximumConcurrentTasks: Int) {
        precondition(maximumTasks > 0)
        precondition(maximumConcurrentTasks > 0)
        self.maximumTasks = maximumTasks
        self.maximumConcurrentTasks = min(maximumConcurrentTasks, maximumTasks)
    }
}

enum ReconstructionTerminalTaskOutcome: Equatable, Sendable {
    case completed
    case failed
    case cancelled
    case staleAuthority
}

/// Exact first-load bytes retained only until the existing checkpoint owner admits them. This
/// value has no Codable conformance and never enters the reconstruction package schema.
struct ReconstructionLoadedImageAdmission: Equatable, Sendable {
    let taskID: UUID
    let snapshot: ReconstructionDetachedAnalysisSnapshot

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.taskID == rhs.taskID
            && lhs.snapshot.artifact == rhs.snapshot.artifact
            && lhs.snapshot.image == rhs.snapshot.image
            && lhs.snapshot.analysisInputFingerprintSHA256 == rhs.snapshot.analysisInputFingerprintSHA256
            && lhs.snapshot.workspace.analysis(in: lhs.snapshot.image.imageSlot)?.imageBytes
                == rhs.snapshot.workspace.analysis(in: rhs.snapshot.image.imageSlot)?.imageBytes
    }
}

/// Transient app-owned source results; the canonical receipt author persists validated evidence.
/// This is neither an analysis snapshot nor a model-selectable tool result. Structural checks
/// below do not authenticate a revision/oracle hash: the receipt owner binds them to committed
/// source and oracle evidence captured in its database cut.
enum ReconstructionSourceTaskExecutionPayload: Equatable, Sendable {
    case oracle(ReconstructionSourceOracle)
    case evaluation(ReconstructionSourceExecutionWorkflow.Outcome)

    func isValid(for task: ReconstructionTaskRecord, authority: ReconstructionBatchAuthority) -> Bool {
        guard ReconstructionSourceExecutionTaskContract.admits(task),
              task.identity.jobID == authority.jobID,
              case .function(let function)? = task.identity.subject else { return false }
        switch self {
        case .oracle(let oracle):
            guard task.identity.operationContractIdentity == ReconstructionSourceExecutionTaskContract.oracle,
                  oracle.jobID == authority.jobID, oracle.function == function,
                  ReconstructionSourceProfile.admits(oracle.profileID),
                  let bytes = try? ReconstructionSourceOracleEvidence.encode(oracle),
                  let validated = try? ReconstructionSourceOracleEvidence.decodeAndValidateCanonical(payload: bytes) else { return false }
            return validated == oracle
        case .evaluation(let outcome):
            guard task.identity.operationContractIdentity == ReconstructionSourceExecutionTaskContract.evaluate,
                  outcome.function == function,
                  case .admittedRevision(let revisionSHA256) = outcome.sourceAuthority,
                  ReconstructionSourceInferenceContract.isSHA256(revisionSHA256),
                  ReconstructionSourceInferenceContract.isSHA256(outcome.sourceSHA256),
                  ReconstructionSourceInferenceContract.isSHA256(outcome.harnessSHA256),
                  outcome.oracleSuiteSHA256.map(ReconstructionSourceInferenceContract.isSHA256) == true,
                  !outcome.phases.isEmpty, outcome.phases.count <= 3,
                  outcome.phases.map(\.request.operation) == Array([Phase2SourceExecutionOperation.inspect, .compile, .behavior]
                    .prefix(outcome.phases.count)),
                  Set(outcome.phases.map(\.request.requestID)).count == outcome.phases.count,
                  Set(outcome.phases.map(\.request.sessionID)).count == 1,
                  Set(outcome.phases.map(\.request.stageRootPath)).count == 1 else { return false }
            for (index, phase) in outcome.phases.enumerated() {
                let request = phase.request
                guard request.isValid, request.sourceAuthority == .admittedRevision,
                      request.revisionSHA256 == revisionSHA256,
                      request.sourceSHA256 == outcome.sourceSHA256, request.harnessSHA256 == outcome.harnessSHA256,
                      request.compilerPath == outcome.toolAuthority.compilerPath,
                      request.sdkRootPath == outcome.toolAuthority.sdkRootPath,
                      request.toolchainRootPath == outcome.toolAuthority.toolchainRootPath,
                      request.runnerSHA256 == outcome.toolAuthority.runnerSHA256,
                      request.compilerSHA256 == outcome.toolAuthority.compilerSHA256,
                      request.sdkSettingsSHA256 == outcome.toolAuthority.sdkSettingsSHA256,
                      phase.transportError == nil, let response = phase.response, response.isValid,
                      response.status == .completed, response.requestID == request.requestID,
                      response.sessionID == request.sessionID, response.operation == request.operation,
                      let cleanup = response.cleanup, cleanup.observedProcessAbsent,
                      cleanup.requestID == request.requestID, cleanup.sessionID == request.sessionID,
                      response.sampledProcessIDs.contains(cleanup.processIdentifier),
                      response.failure != nil || (response.terminal != nil && cleanup.outcome == response.terminal) else { return false }
                if index + 1 < outcome.phases.count {
                    guard response.failure == nil, response.terminal == .init(kind: .exited, status: 0) else { return false }
                }
            }
            if outcome.failure == nil || outcome.failure == .behaviorMismatch {
                guard outcome.phases.count == 3, let ast = outcome.astAdmission,
                      ast.sourceSHA256 == outcome.sourceSHA256,
                      ast.profileID == outcome.phases.first?.request.sourceProfile?.rawValue,
                      outcome.inspection?.sha256 == ast.astSHA256, outcome.executable != nil,
                      let harness = try? ReconstructionSourceBehaviorHarness.forProfile(ast.profileID),
                      outcome.observations.map(\.input) == harness.inputs,
                      outcome.phases.allSatisfy({ $0.response?.failure == nil
                        && $0.response?.terminal == .init(kind: .exited, status: 0) }),
                      (outcome.failure == nil ? outcome.mismatches.isEmpty : !outcome.mismatches.isEmpty),
                      Set(outcome.mismatches.map(\.index)).count == outcome.mismatches.count,
                      outcome.mismatches.allSatisfy({ mismatch in
                          harness.inputs.indices.contains(mismatch.index)
                              && mismatch.input == harness.inputs[mismatch.index]
                              && mismatch.actual == outcome.observations[mismatch.index].output
                              && mismatch.expected != mismatch.actual
                      }) else { return false }
            }
            return true
        }
    }
}

struct ReconstructionTerminalTaskResult: Equatable, Sendable {
    let jobID: UUID
    let taskID: UUID
    let checkpointID: UUID
    let checkpointRevision: UInt64
    let corpusManifestSHA256: String
    let outcome: ReconstructionTerminalTaskOutcome
    let analysisProjection: ReconstructionTransientAnalysisProjection?
    let nativeResult: ReconstructionNativeTaskResult?
    let loadedImageAdmission: ReconstructionLoadedImageAdmission?
    let sourceExecution: ReconstructionSourceTaskExecutionPayload?
    /// D13: a completed decompile/compare task whose native decompiler failed closed carries the
    /// MacIR fallback reason instead of a native result. Kept only on `.completed`.
    let decompileFallbackReason: String?
    /// The concrete failure (e.g. harness case, build excerpt, broker error kind). Kept only on
    /// `.failed`; becomes the task diagnostic and the job's terminal reason.
    let failureDiagnostic: ReconstructionDiagnostic?

    init(
        jobID: UUID,
        taskID: UUID,
        checkpointID: UUID,
        checkpointRevision: UInt64,
        corpusManifestSHA256: String,
        outcome: ReconstructionTerminalTaskOutcome,
        analysisProjection: ReconstructionTransientAnalysisProjection? = nil,
        nativeResult: ReconstructionNativeTaskResult? = nil,
        loadedImageAdmission: ReconstructionLoadedImageAdmission? = nil,
        sourceExecution: ReconstructionSourceTaskExecutionPayload? = nil,
        decompileFallbackReason: String? = nil,
        failureDiagnostic: ReconstructionDiagnostic? = nil
    ) {
        self.decompileFallbackReason = outcome == .completed && nativeResult == nil ? decompileFallbackReason : nil
        self.failureDiagnostic = outcome == .failed ? failureDiagnostic : nil
        self.jobID = jobID
        self.taskID = taskID
        self.checkpointID = checkpointID
        self.checkpointRevision = checkpointRevision
        self.corpusManifestSHA256 = corpusManifestSHA256
        self.outcome = outcome
        if outcome == .completed {
            self.analysisProjection = analysisProjection
            self.nativeResult = nativeResult
            self.loadedImageAdmission = loadedImageAdmission
            self.sourceExecution = sourceExecution
        } else {
            self.analysisProjection = nil
            self.nativeResult = nil
            self.loadedImageAdmission = nil
            self.sourceExecution = nil
        }
    }
}

private enum ReconstructionTaskExecutionDomain: Equatable, Sendable {
    case batch
    case evidenceRead
    case model
    case checkpoint

    init(_ kind: ReconstructionTaskKind) {
        switch kind {
        case .ingest, .classify, .discoverRelations,
             .loadBinary, .indexImage, .enumerateFunctions,
             .decompileNative, .decompileMacScope, .compareDecompilers, .executeSource:
            self = .batch
        case .retrieveEvidence:
            self = .evidenceRead
        case .modelRound:
            self = .model
        case .checkpoint:
            self = .checkpoint
        }
    }
}

private struct ReconstructionScheduledTaskCompletion: Sendable {
    let task: ReconstructionTaskRecord
    let result: ReconstructionTerminalTaskResult
}

protocol ReconstructionBatchTaskExecuting: Sendable {
    func execute(
        task: ReconstructionTaskRecord,
        authority: ReconstructionBatchAuthority,
        cancellation: ReconstructionCancellation
    ) async -> ReconstructionTerminalTaskResult

    func pause() async
    func resume() async
    func retire() async
}

enum ReconstructionBatchSchedulerError: Error, Equatable, Sendable {
    case jobAuthorityMismatch(expected: UUID, actual: UUID)
    case jobPaused(UUID)
    case jobRetired(UUID)
}

actor ReconstructionBatchScheduler {
    private enum Lifecycle {
        case active
        case paused
        case retired
    }

    private let durableJobID: UUID
    private let executor: any ReconstructionBatchTaskExecuting
    private let planner: ReconstructionTaskPlanner
    private var cancellation = ReconstructionCancellation()
    private var lifecycle: Lifecycle = .active

    init(
        durableJobID: UUID,
        executor: any ReconstructionBatchTaskExecuting,
        planner: ReconstructionTaskPlanner = .init()
    ) {
        self.durableJobID = durableJobID
        self.executor = executor
        self.planner = planner
    }

    func executeReadyTasks(
        _ tasks: [ReconstructionTaskRecord],
        authority: ReconstructionBatchAuthority,
        budget: ReconstructionBatchBudget,
        allowedTaskKinds: Set<ReconstructionTaskKind>? = nil
    ) async throws -> [ReconstructionTerminalTaskResult] {
        guard authority.jobID == durableJobID else {
            throw ReconstructionBatchSchedulerError.jobAuthorityMismatch(
                expected: durableJobID,
                actual: authority.jobID
            )
        }
        switch lifecycle {
        case .active:
            break
        case .paused:
            throw ReconstructionBatchSchedulerError.jobPaused(durableJobID)
        case .retired:
            throw ReconstructionBatchSchedulerError.jobRetired(durableJobID)
        }

        let ready = try planner.readyTasks(
            from: tasks,
            jobID: durableJobID,
            maximumTasks: budget.maximumTasks
        ).filter {
            ReconstructionTaskExecutionDomain($0.identity.kind) == .batch
                && (allowedTaskKinds?.contains($0.identity.kind) ?? true)
        }
        let executionCancellation = cancellation
        var completions: [ReconstructionScheduledTaskCompletion] = []
        var nextIndex = 0
        await withTaskGroup(of: ReconstructionScheduledTaskCompletion.self) { group in
            func submitNext() {
                guard nextIndex < ready.count else { return }
                let task = ready[nextIndex]
                nextIndex += 1
                group.addTask { [executor] in
                    let result = await executor.execute(
                        task: task,
                        authority: authority,
                        cancellation: executionCancellation
                    )
                    return .init(task: task, result: result)
                }
            }
            for _ in 0..<min(budget.maximumConcurrentTasks, ready.count) { submitNext() }
            while let completion = await group.next() {
                completions.append(completion)
                submitNext()
            }
        }
        guard lifecycle == .active, cancellation === executionCancellation else {
            return staleResults(completions, authority: authority)
        }
        return completions.sorted {
            $0.task.identity.taskID.uuidString.lowercased()
                < $1.task.identity.taskID.uuidString.lowercased()
        }.map { completion in
            validatedResult(completion, authority: authority)
        }
    }

    func pause(jobID: UUID) async {
        guard jobID == durableJobID, lifecycle == .active else { return }
        lifecycle = .paused
        cancellation.cancel()
        await executor.pause()
    }

    func resume(jobID: UUID) async {
        guard jobID == durableJobID, lifecycle == .paused else { return }
        await executor.resume()
        guard lifecycle == .paused else { return }
        cancellation = ReconstructionCancellation()
        lifecycle = .active
    }

    func retire(jobID: UUID) async {
        guard jobID == durableJobID, lifecycle != .retired else { return }
        lifecycle = .retired
        cancellation.cancel()
        await executor.retire()
    }

    private func staleResults(
        _ completions: [ReconstructionScheduledTaskCompletion],
        authority: ReconstructionBatchAuthority
    ) -> [ReconstructionTerminalTaskResult] {
        completions.sorted {
            $0.task.identity.taskID.uuidString.lowercased()
                < $1.task.identity.taskID.uuidString.lowercased()
        }.map {
            staleResult(expectedTaskID: $0.task.identity.taskID, authority: authority)
        }
    }

    private func validatedResult(
        _ completion: ReconstructionScheduledTaskCompletion,
        authority: ReconstructionBatchAuthority
    ) -> ReconstructionTerminalTaskResult {
        let task = completion.task
        let result = completion.result
        guard result.jobID == authority.jobID,
              result.taskID == task.identity.taskID,
              result.checkpointID == authority.checkpointID,
              result.checkpointRevision == authority.checkpointRevision,
              result.corpusManifestSHA256 == authority.corpusManifestSHA256 else {
            return staleResult(expectedTaskID: task.identity.taskID, authority: authority)
        }
        guard result.outcome == .completed else {
            // F3: payloads are dropped for a non-completed outcome, but a failed task keeps its
            // bounded concrete diagnostic (it becomes the task diagnostic and the job reason).
            return .init(
                jobID: authority.jobID,
                taskID: task.identity.taskID,
                checkpointID: authority.checkpointID,
                checkpointRevision: authority.checkpointRevision,
                corpusManifestSHA256: authority.corpusManifestSHA256,
                outcome: result.outcome,
                failureDiagnostic: result.failureDiagnostic
            )
        }
        guard completedPayloadIsValid(result, for: task, authority: authority) else {
            return staleResult(expectedTaskID: task.identity.taskID, authority: authority)
        }
        return result
    }

    private func completedPayloadIsValid(
        _ result: ReconstructionTerminalTaskResult,
        for task: ReconstructionTaskRecord,
        authority: ReconstructionBatchAuthority
    ) -> Bool {
        guard task.identity.kind == .executeSource || result.sourceExecution == nil else { return false }
        switch task.identity.kind {
        case .executeSource:
            return result.analysisProjection == nil && result.nativeResult == nil
                && result.loadedImageAdmission == nil
                && result.sourceExecution?.isValid(for: task, authority: authority) == true
        case .ingest, .classify, .discoverRelations:
            return result.analysisProjection == nil && result.nativeResult == nil
        case .loadBinary, .indexImage, .enumerateFunctions:
            return result.nativeResult == nil
                && result.analysisProjection.map {
                    projectionMatches($0, task: task)
                } == true
        case .decompileMacScope:
            return result.nativeResult == nil
                && result.analysisProjection.map {
                    projectionMatches($0, task: task) && $0.macScopePseudocode != nil
                } == true
        case .decompileNative, .compareDecompilers:
            guard let projection = result.analysisProjection,
                  projectionMatches(projection, task: task),
                  task.identity.kind != .compareDecompilers
                    || projection.macScopePseudocode != nil else {
                return false
            }
            // D13: native failed closed; the MacIR fallback carries a reason and no native bytes.
            if result.nativeResult == nil, let reason = result.decompileFallbackReason {
                return !reason.isEmpty
            }
            guard case .completed(let success)? = result.nativeResult else {
                return false
            }
            return success.taskID == task.identity.taskID
                && success.checkpointID == authority.checkpointID
                && success.checkpointRevision == authority.checkpointRevision
                && success.corpusManifestSHA256 == authority.corpusManifestSHA256
                && success.execution.imageSlot == projection.image.imageSlot
                && success.execution.functionID == projection.function?.id
                && success.execution.analysisInputFingerprintSHA256
                    == projection.analysisFingerprintSHA256
        case .retrieveEvidence, .modelRound, .checkpoint:
            return false
        }
    }

    private func projectionMatches(
        _ projection: ReconstructionTransientAnalysisProjection,
        task: ReconstructionTaskRecord
    ) -> Bool {
        guard projection.taskID == task.identity.taskID,
              projection.taskKind == task.identity.kind else {
            return false
        }
        switch task.identity.subject {
        case .artifact(let artifact):
            return projection.artifact == artifact
        case .image(let image):
            return projection.artifact == image.artifact
                && projection.image == image.image
                && projection.analysisFingerprintSHA256 == image.analysisFingerprintSHA256
        case .function(let function):
            guard let projectedFunction = projection.function else {
                return false
            }
            return projection.artifact == function.artifact
                && projection.image == function.image
                && projection.analysisFingerprintSHA256
                    == function.analysisFingerprintSHA256
                && ReconstructionReboundFunctionAuthority.matches(
                    projectedFunction,
                    coordinate: function
                )
        case nil:
            return false
        }
    }

    private func staleResult(
        expectedTaskID: UUID,
        authority: ReconstructionBatchAuthority
    ) -> ReconstructionTerminalTaskResult {
        .init(
            jobID: authority.jobID,
            taskID: expectedTaskID,
            checkpointID: authority.checkpointID,
            checkpointRevision: authority.checkpointRevision,
            corpusManifestSHA256: authority.corpusManifestSHA256,
            outcome: .staleAuthority
        )
    }
}
