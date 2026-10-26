import Foundation

struct ReconstructionProductionCommittedRoundCut: Sendable {
    let snapshot: ReconstructionJobOrchestrationSnapshot
    let parentCheckpointID: UUID
    let parentCheckpointSHA256: String
    let prepared: ReconstructionPreparedModelRound
    /// Terminal results produced by `ReconstructionBatchScheduler` from the persisted task cut.
    /// Results remain transient until the plan builder translates them into one atomic mutation.
    let batchTerminalResults: [ReconstructionTerminalTaskResult]
}

/// Runtime/database composition captures one immutable committed cut. Implementations may own DB
/// handles; the returned value deliberately cannot expose them to the model planner.
protocol ReconstructionProductionCommittedRoundCutProviding: Sendable {
    func capture(
        snapshot: ReconstructionJobOrchestrationSnapshot
    ) async throws -> ReconstructionProductionCommittedRoundCut
}

/// Turns immutable cuts and terminal executions into complete durable mutations. UI and Store
/// state are intentionally absent from every signature.
protocol ReconstructionProductionRoundPlanBuilding: Sendable {
    /// Returns a complete atomic plan when this cut contains deterministic batch progress or a
    /// graph transition that must commit before inference. `nil` explicitly authorizes the model
    /// branch and is invalid while uncommitted terminal batch results remain.
    func makePreInferenceCommitPlan(
        cut: ReconstructionProductionCommittedRoundCut
    ) async throws -> ReconstructionJobCommitPlan?
    func makeSourceCommitPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        source: ReconstructionSourceRevisionExecutionResult
    ) async throws -> ReconstructionJobCommitPlan
    func makeCommitPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        inference: ReconstructionInferenceExecutionResult,
        executions: [ReconstructionToolExecution]
    ) async throws -> ReconstructionJobCommitPlan
    func makeFailedModelPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        reason: ReconstructionJobCoordinatorFailure
    ) async throws -> ReconstructionJobCommitPlan
    func makeFinalCommitPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        synthesis: ReconstructionFinalSynthesisExecutionResult
    ) async throws -> ReconstructionJobCommitPlan
    func makeRecoveryPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        transitions: [ReconstructionTaskTransition]
    ) async throws -> ReconstructionJobCommitPlan
    func makeControlPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        reason: ReconstructionJobPauseReason
    ) async throws -> ReconstructionJobCommitPlan

    /// Releases any plan-builder authority created while capturing this exact cut. The
    /// materializer invokes this only for a prepared model round that will not be consumed.
    func discardPreparedRound(
        cut: ReconstructionProductionCommittedRoundCut
    ) async
}

extension ReconstructionProductionRoundPlanBuilding {
    func makeSourceCommitPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        source: ReconstructionSourceRevisionExecutionResult
    ) async throws -> ReconstructionJobCommitPlan {
        throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
    }
}

/// Production implementation. The actor retains only immutable DTO cuts between prepare and
/// commit; it has no UI, Store, scheduler, or database authority of its own.
actor ReconstructionProductionJobRoundMaterializer: ReconstructionJobRoundMaterializing {
    private let cutProvider: any ReconstructionProductionCommittedRoundCutProviding
    private let planBuilder: any ReconstructionProductionRoundPlanBuilding
    private var cutsByRoundID: [UUID: ReconstructionProductionCommittedRoundCut] = [:]

    init(
        cutProvider: any ReconstructionProductionCommittedRoundCutProviding,
        planBuilder: any ReconstructionProductionRoundPlanBuilding
    ) {
        self.cutProvider = cutProvider
        self.planBuilder = planBuilder
    }

    func prepare(
        snapshot: ReconstructionJobOrchestrationSnapshot
    ) async throws -> ReconstructionRoundPreparation {
        if snapshot.tasks.contains(where: { $0.identity.kind == .retrieveEvidence && $0.state == .running }) {
            ReconstructionResumeFaultInjection.shared.hit("retrieveEvidence")
        }
        let cut = try await validatedCut(for: snapshot)
        if let plan = try await planBuilder.makePreInferenceCommitPlan(cut: cut) {
            return .commit(try validatePlan(plan, cut: cut))
        }
        guard cut.batchTerminalResults.isEmpty else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        guard cutsByRoundID[cut.prepared.roundID] == nil else {
            throw ReconstructionJobCoordinatorFailure.malformedOutput
        }
        cutsByRoundID[cut.prepared.roundID] = cut
        return .model(cut.prepared)
    }

    func discardPreparedRound(
        snapshot: ReconstructionJobOrchestrationSnapshot,
        prepared: ReconstructionPreparedModelRound
    ) async {
        guard let cut = cutsByRoundID[prepared.roundID], cut.snapshot == snapshot else { return }
        cutsByRoundID[prepared.roundID] = nil
        await planBuilder.discardPreparedRound(cut: cut)
    }

    func makeSourceCommitPlan(
        snapshot: ReconstructionJobOrchestrationSnapshot,
        prepared: ReconstructionPreparedModelRound,
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        source: ReconstructionSourceRevisionExecutionResult
    ) async throws -> ReconstructionJobCommitPlan {
        let cut = try consumeCut(snapshot: snapshot, prepared: prepared)
        guard let request = cut.prepared.sourceRevisionRequest,
              requestAuthority.request == .sourceRevision(request),
              requestAuthority.terminalReceipt == source.terminalReceipt,
              source.terminalReceipt.status == .completed,
              (try? source.candidate.validate(for: request)) != nil else {
            throw ReconstructionJobCoordinatorFailure.malformedOutput
        }
        try ReconstructionProductionJobRoundPlanner.validateSourceRequest(
            request, prepared: cut.prepared, snapshot: cut.snapshot
        )
        return try validatePlan(
            await planBuilder.makeSourceCommitPlan(
                cut: cut, lease: lease, requestAuthority: requestAuthority, source: source
            ), cut: cut
        )
    }

    func makeCommitPlan(
        snapshot: ReconstructionJobOrchestrationSnapshot,
        prepared: ReconstructionPreparedModelRound,
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        inference: ReconstructionInferenceExecutionResult,
        executions: [ReconstructionToolExecution]
    ) async throws -> ReconstructionJobCommitPlan {
        let cut = try consumeCut(snapshot: snapshot, prepared: prepared)
        return try validatePlan(
            await planBuilder.makeCommitPlan(
                cut: cut,
                lease: lease,
                requestAuthority: requestAuthority,
                inference: inference,
                executions: executions
            ),
            cut: cut
        )
    }

    func makeFailedModelPlan(
        snapshot: ReconstructionJobOrchestrationSnapshot,
        prepared: ReconstructionPreparedModelRound,
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        reason: ReconstructionJobCoordinatorFailure
    ) async throws -> ReconstructionJobCommitPlan {
        let cut = try consumeCut(snapshot: snapshot, prepared: prepared)
        let plan = try await planBuilder.makeFailedModelPlan(
            cut: cut,
            lease: lease,
            requestAuthority: requestAuthority,
            reason: reason
        )
        guard plan.disposition == (try Self.failedModelDisposition(for: reason)) else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        return try validatePlan(plan, cut: cut)
    }

    func makeFinalCommitPlan(
        snapshot: ReconstructionJobOrchestrationSnapshot,
        prepared: ReconstructionPreparedModelRound,
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        synthesis: ReconstructionFinalSynthesisExecutionResult
    ) async throws -> ReconstructionJobCommitPlan {
        let cut = try consumeCut(snapshot: snapshot, prepared: prepared)
        let plan = try await planBuilder.makeFinalCommitPlan(
            cut: cut,
            lease: lease,
            requestAuthority: requestAuthority,
            synthesis: synthesis
        )
        guard plan.disposition == .completed else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        return try validatePlan(plan, cut: cut)
    }

    func makeRecoveryPlan(
        snapshot: ReconstructionJobOrchestrationSnapshot,
        transitions: [ReconstructionTaskTransition]
    ) async throws -> ReconstructionJobCommitPlan {
        let cut = try await validatedCut(for: snapshot)
        guard !transitions.isEmpty else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        let tasksByID = Dictionary(uniqueKeysWithValues: snapshot.tasks.map {
            ($0.identity.taskID, $0)
        })
        guard Set(transitions.map(\.taskID)).count == transitions.count,
              transitions.allSatisfy({ transition in
                  tasksByID[transition.taskID]?.state == transition.expectedState
                    && transition.expectedState != transition.successorState
              }) else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        return try validatePlan(
            await planBuilder.makeRecoveryPlan(cut: cut, transitions: transitions),
            cut: cut
        )
    }

    func makeControlPlan(
        snapshot: ReconstructionJobOrchestrationSnapshot,
        reason: ReconstructionJobPauseReason
    ) async throws -> ReconstructionJobCommitPlan {
        let cut = try await validatedCut(for: snapshot)
        let plan = try await planBuilder.makeControlPlan(cut: cut, reason: reason)
        guard plan.disposition == reason.controlDisposition else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        return try validatePlan(plan, cut: cut)
    }

    static func validateCommittedAuthority(
        _ captured: ReconstructionJobOrchestrationSnapshot,
        against requested: ReconstructionJobOrchestrationSnapshot
    ) throws {
        guard captured == requested else {
            throw ReconstructionJobCoordinatorFailure.malformedOutput
        }
    }

    static func validateDurablePlan(
        _ plan: ReconstructionJobCommitPlan,
        against snapshot: ReconstructionJobOrchestrationSnapshot
    ) throws {
        guard plan.successorRevision == snapshot.checkpointRevision + 1,
              plan.acceptedEvidenceCount >= 0,
              let mutation = plan.mutation,
              mutation.jobID == snapshot.jobID,
              mutation.expectedParentRevision == snapshot.checkpointRevision,
              mutation.successorCheckpoint.jobID == snapshot.jobID,
              mutation.successorCheckpoint.revision == plan.successorRevision,
              mutation.successorCheckpoint.corpusManifestSHA256
                == snapshot.currentCorpusManifestSHA256 else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        try validateDispositionAuthority(plan, mutation: mutation, snapshot: snapshot)
        try validateNewTasks(mutation.newTasks, against: snapshot)
    }

    static func failedModelDisposition(
        for failure: ReconstructionJobCoordinatorFailure
    ) throws -> ReconstructionJobCoordinatorDisposition {
        switch failure {
        case .modelUnavailable, .retryableProviderFailure:
            .paused(.modelUnavailable)
        case .inferenceBusy:
            .paused(.inferenceBusy)
        case .malformedOutput, .modelChanged:
            .failed
        case .invalidCommitPlan, .jobNotFound, .checkpointConflict:
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
    }

    private static func validateDispositionAuthority(
        _ plan: ReconstructionJobCommitPlan,
        mutation: ReconstructionCheckpointMutation,
        snapshot: ReconstructionJobOrchestrationSnapshot
    ) throws {
        let checkpoint = mutation.successorCheckpoint
        guard (snapshot.currentDurableJobState == .paused) == (snapshot.pauseContext != nil) else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }

        switch plan.disposition {
        case .advancePhase(let phase):
            guard checkpoint.coordinatorState == phase,
                  checkpoint.terminalReason == nil,
                  mutation.successorPauseContext == nil else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            try validateTransition(from: snapshot, to: phase, successorPauseContext: nil)
            try ReconstructionProductionRoundPlanBuilder.validatePhaseAuthority(
                phase, mutation: mutation, snapshot: snapshot
            )
        case .continue:
            guard let activeState = snapshot.currentDurableActiveState,
                  checkpoint.coordinatorState == activeState,
                  checkpoint.terminalReason == nil,
                  mutation.successorPauseContext == nil else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            try validateTransition(
                from: snapshot,
                to: activeState,
                successorPauseContext: nil
            )
        case .completed:
            guard checkpoint.coordinatorState == .completed,
                  checkpoint.terminalReason == nil,
                  mutation.successorPauseContext == nil else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            try validateTransition(
                from: snapshot,
                to: .completed,
                successorPauseContext: nil
            )
        case .paused(let reason):
            guard let cause = reason.durablePauseCause,
                  let activeState = snapshot.currentDurableActiveState,
                  snapshot.currentDurableJobState != .paused,
                  checkpoint.coordinatorState == .paused,
                  checkpoint.terminalReason == nil,
                  mutation.successorPauseContext?.cause == cause,
                  mutation.successorPauseContext?.resumeTarget == activeState else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            try validateTransition(
                from: snapshot,
                to: .paused,
                successorPauseContext: mutation.successorPauseContext
            )
        case .cancelled:
            guard checkpoint.coordinatorState == .cancelled,
                  checkpoint.terminalReason != nil,
                  mutation.successorPauseContext == nil else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            try validateTransition(
                from: snapshot,
                to: .cancelled,
                successorPauseContext: nil
            )
        case .failed:
            guard checkpoint.coordinatorState == .failed,
                  checkpoint.terminalReason != nil,
                  mutation.successorPauseContext == nil else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            try validateTransition(
                from: snapshot,
                to: .failed,
                successorPauseContext: nil
            )
        }
    }

    private static func validateTransition(
        from snapshot: ReconstructionJobOrchestrationSnapshot,
        to successorState: ReconstructionJobState,
        successorPauseContext: ReconstructionJobPauseContext?
    ) throws {
        if snapshot.currentDurableJobState == successorState,
           ReconstructionJobState.activeStates.contains(successorState),
           snapshot.pauseContext == nil,
           successorPauseContext == nil {
            return
        }
        let resumeTarget: ReconstructionJobState? = if snapshot.currentDurableJobState == .paused {
            successorState == .cancelled || successorState == .failed
                ? nil
                : snapshot.pauseContext?.resumeTarget
        } else if successorState == .paused {
            successorPauseContext?.resumeTarget
        } else {
            nil
        }
        do {
            try ReconstructionJobStateMachine.transition(
                from: snapshot.currentDurableJobState,
                to: successorState,
                resumeTarget: resumeTarget
            )
        } catch {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
    }

    static func validateNewTasks(
        _ tasks: [ReconstructionTaskRecord],
        against snapshot: ReconstructionJobOrchestrationSnapshot
    ) throws {
        let existingIDs = Set(snapshot.tasks.map(\.identity.taskID))
        let newIDs = tasks.map(\.identity.taskID)
        guard Set(newIDs).count == newIDs.count,
              existingIDs.isDisjoint(with: newIDs),
              tasks.allSatisfy({ $0.identity.jobID == snapshot.jobID && $0.state == .pending }) else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        let allowedIDs = existingIDs.union(newIDs)
        guard tasks.allSatisfy({ task in
            Set(task.identity.dependencyTaskIDs).isSubset(of: allowedIDs)
        }) else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
    }

    private func validatedCut(
        for snapshot: ReconstructionJobOrchestrationSnapshot
    ) async throws -> ReconstructionProductionCommittedRoundCut {
        let cut = try await cutProvider.capture(snapshot: snapshot)
        do {
            try Self.validateCommittedAuthority(cut.snapshot, against: snapshot)
            try ReconstructionValidation.requireSHA256(
                cut.parentCheckpointSHA256,
                field: "production round parent checkpoint"
            )
            let authority = cut.prepared.authority
            guard authority.jobID == snapshot.jobID,
                  authority.checkpointRevision == snapshot.checkpointRevision,
                  authority.corpusManifestSHA256 == snapshot.currentCorpusManifestSHA256,
                  authority.evidenceFrontierSHA256 == snapshot.evidenceFrontierSHA256,
                  cut.prepared.evidenceCut.corpusManifestSHA256
                    == snapshot.currentCorpusManifestSHA256,
                  cut.prepared.evidenceCut.frontierSHA256 == snapshot.evidenceFrontierSHA256 else {
                throw ReconstructionJobCoordinatorFailure.malformedOutput
            }
            let knownTaskIDs = Set(snapshot.tasks.map(\.identity.taskID))
            let resultIDs = cut.batchTerminalResults.map(\.taskID)
            guard Set(resultIDs).count == resultIDs.count,
                  Set(resultIDs).isSubset(of: knownTaskIDs),
                  cut.batchTerminalResults.allSatisfy({ result in
                      result.jobID == snapshot.jobID
                        && result.checkpointID == cut.parentCheckpointID
                        && result.checkpointRevision == snapshot.checkpointRevision
                        && result.corpusManifestSHA256 == snapshot.currentCorpusManifestSHA256
                        && result.outcome != .staleAuthority
                  }) else {
                throw ReconstructionJobCoordinatorFailure.malformedOutput
            }
            return cut
        } catch {
            await planBuilder.discardPreparedRound(cut: cut)
            throw error
        }
    }

    private func consumeCut(
        snapshot: ReconstructionJobOrchestrationSnapshot,
        prepared: ReconstructionPreparedModelRound
    ) throws -> ReconstructionProductionCommittedRoundCut {
        guard let cut = cutsByRoundID.removeValue(forKey: prepared.roundID) else {
            throw ReconstructionJobCoordinatorFailure.malformedOutput
        }
        try Self.validateCommittedAuthority(cut.snapshot, against: snapshot)
        guard cut.prepared.roundID == prepared.roundID,
              cut.prepared.authority == prepared.authority,
              cut.prepared.objective == prepared.objective,
              cut.prepared.sourceRevisionRequest == prepared.sourceRevisionRequest,
              cut.prepared.sourceOracleFunction == prepared.sourceOracleFunction,
              cut.prepared.sourceOracleRequested == prepared.sourceOracleRequested,
              cut.prepared.finalSynthesisRequest == prepared.finalSynthesisRequest else {
            throw ReconstructionJobCoordinatorFailure.malformedOutput
        }
        return cut
    }

    private func validatePlan(
        _ plan: ReconstructionJobCommitPlan,
        cut: ReconstructionProductionCommittedRoundCut
    ) throws -> ReconstructionJobCommitPlan {
        try Self.validateDurablePlan(plan, against: cut.snapshot)
        guard let mutation = plan.mutation,
              mutation.expectedParentCheckpointID == cut.parentCheckpointID,
              mutation.expectedParentCheckpointSHA256 == cut.parentCheckpointSHA256,
              mutation.successorCheckpoint.parentCheckpointID == cut.parentCheckpointID,
              mutation.successorCheckpoint.parentCheckpointSHA256 == cut.parentCheckpointSHA256 else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        return plan
    }
}
